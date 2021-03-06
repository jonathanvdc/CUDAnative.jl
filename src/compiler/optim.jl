# LLVM IR optimization

function optimize!(ctx::CompilerContext, mod::LLVM.Module, entry::LLVM.Function)
    tm = machine(ctx.cap, triple(mod))

    if ctx.kernel
        entry = promote_kernel!(ctx, mod, entry)
    end

    let pm = ModulePassManager()
        global global_ctx
        global_ctx = ctx

        add_library_info!(pm, triple(mod))
        add_transform_info!(pm, tm)
        internalize!(pm, [LLVM.name(entry)])

        ccall(:jl_add_optimization_passes, Cvoid,
              (LLVM.API.LLVMPassManagerRef, Cint, Cint),
              LLVM.ref(pm), Base.JLOptions().opt_level, 1)

        # lower intrinsics
        add!(pm, ModulePass("FinalLowerGCGPU", lower_final_gc_intrinsics!))
        aggressive_dce!(pm) # remove dead uses of ptls
        add!(pm, ModulePass("LowerPTLS", lower_ptls!))

        # NVPTX's target machine info enables runtime unrolling,
        # but Julia's pass sequence only invokes the simple unroller.
        loop_unroll!(pm)
        instruction_combining!(pm)  # clean-up redundancy
        licm!(pm)                   # the inner runtime check might be outer loop invariant

        # the above loop unroll pass might have unrolled regular, non-runtime nested loops.
        # that code still needs to be optimized (arguably, multiple unroll passes should be
        # scheduled by the Julia optimizer). do so here, instead of re-optimizing entirely.
        early_csemem_ssa!(pm) # TODO: gvn instead? see NVPTXTargetMachine.cpp::addEarlyCSEOrGVNPass
        dead_store_elimination!(pm)

        constant_merge!(pm)

        # NOTE: if an optimization is missing, try scheduling an entirely new optimization
        # to see which passes need to be added to the list above
        #     LLVM.clopts("-print-after-all", "-filter-print-funcs=$(LLVM.name(entry))")
        #     ModulePassManager() do pm
        #         add_library_info!(pm, triple(mod))
        #         add_transform_info!(pm, tm)
        #         PassManagerBuilder() do pmb
        #             populate!(pm, pmb)
        #         end
        #         run!(pm, mod)
        #     end

        cfgsimplification!(pm)

        run!(pm, mod)
        dispose(pm)
    end

    # we compile a module containing the entire call graph,
    # so perform some interprocedural optimizations.
    #
    # for some reason, these passes need to be distinct from the regular optimization chain,
    # or certain values (such as the constant arrays used to populare llvm.compiler.user ad
    # part of the LateLowerGCFrame pass) aren't collected properly.
    #
    # these might not always be safe, as Julia's IR metadata isn't designed for IPO.
    let pm = ModulePassManager()
        dead_arg_elimination!(pm)   # parent doesn't use return value --> ret void

        run!(pm, mod)
        dispose(pm)
    end

    return entry
end


## kernel-specific optimizations

# promote a function to a kernel
# FIXME: sig vs tt (code_llvm vs cufunction)
function promote_kernel!(ctx::CompilerContext, mod::LLVM.Module, entry_f::LLVM.Function)
    kernel = wrap_entry!(ctx, mod, entry_f)

    # property annotations
    # TODO: belongs in irgen? doesn't maxntidx doesn't appear in ptx code?

    annotations = LLVM.Value[kernel]

    ## kernel metadata
    append!(annotations, [MDString("kernel"), ConstantInt(Int32(1), JuliaContext())])

    ## expected CTA sizes
    if ctx.minthreads != nothing
        bounds = CUDAdrv.CuDim3(ctx.minthreads)
        for dim in (:x, :y, :z)
            bound = getfield(bounds, dim)
            append!(annotations, [MDString("reqntid$dim"),
                                  ConstantInt(Int32(bound), JuliaContext())])
        end
    end
    if ctx.maxthreads != nothing
        bounds = CUDAdrv.CuDim3(ctx.maxthreads)
        for dim in (:x, :y, :z)
            bound = getfield(bounds, dim)
            append!(annotations, [MDString("maxntid$dim"),
                                  ConstantInt(Int32(bound), JuliaContext())])
        end
    end

    if ctx.blocks_per_sm != nothing
        append!(annotations, [MDString("minctasm"),
                              ConstantInt(Int32(ctx.blocks_per_sm), JuliaContext())])
    end

    if ctx.maxregs != nothing
        append!(annotations, [MDString("maxnreg"),
                              ConstantInt(Int32(ctx.maxregs), JuliaContext())])
    end


    push!(metadata(mod), "nvvm.annotations", MDNode(annotations))


    return kernel
end

function wrapper_type(julia_t::Type, codegen_t::LLVMType)::LLVMType
    if !isbitstype(julia_t)
        # don't pass jl_value_t by value; it's an opaque structure
        return codegen_t
    elseif isa(codegen_t, LLVM.PointerType) && !(julia_t <: Ptr)
        # we didn't specify a pointer, but codegen passes one anyway.
        # make the wrapper accept the underlying value instead.
        return eltype(codegen_t)
    else
        return codegen_t
    end
end

# generate a kernel wrapper to fix & improve argument passing
function wrap_entry!(ctx::CompilerContext, mod::LLVM.Module, entry_f::LLVM.Function)
    entry_ft = eltype(llvmtype(entry_f)::LLVM.PointerType)::LLVM.FunctionType
    @compiler_assert return_type(entry_ft) == LLVM.VoidType(JuliaContext()) ctx

    # filter out ghost types, which don't occur in the LLVM function signatures
    sig = Base.signature_type(ctx.f, ctx.tt)::Type
    julia_types = Type[]
    for dt::Type in sig.parameters
        if !isghosttype(dt)
            push!(julia_types, dt)
        end
    end

    # generate the wrapper function type & definition
    wrapper_types = LLVM.LLVMType[wrapper_type(julia_t, codegen_t)
                                  for (julia_t, codegen_t)
                                  in zip(julia_types, parameters(entry_ft))]
    wrapper_fn = replace(LLVM.name(entry_f), r"^.+?_"=>"ptxcall_") # change the CC tag
    wrapper_ft = LLVM.FunctionType(LLVM.VoidType(JuliaContext()), wrapper_types)
    wrapper_f = LLVM.Function(mod, wrapper_fn, wrapper_ft)

    # emit IR performing the "conversions"
    let builder = Builder(JuliaContext())
        entry = BasicBlock(wrapper_f, "entry", JuliaContext())
        position!(builder, entry)

        wrapper_args = Vector{LLVM.Value}()

        # perform argument conversions
        codegen_types = parameters(entry_ft)
        wrapper_params = parameters(wrapper_f)
        param_index = 0
        for (julia_t, codegen_t, wrapper_t, wrapper_param) in
            zip(julia_types, codegen_types, wrapper_types, wrapper_params)
            param_index += 1
            if codegen_t != wrapper_t
                # the wrapper argument doesn't match the kernel parameter type.
                # this only happens when codegen wants to pass a pointer.
                @compiler_assert isa(codegen_t, LLVM.PointerType) ctx
                @compiler_assert eltype(codegen_t) == wrapper_t ctx

                # copy the argument value to a stack slot, and reference it.
                ptr = alloca!(builder, wrapper_t)
                if LLVM.addrspace(codegen_t) != 0
                    ptr = addrspacecast!(builder, ptr, codegen_t)
                end
                store!(builder, wrapper_param, ptr)
                push!(wrapper_args, ptr)
            else
                push!(wrapper_args, wrapper_param)
                for attr in collect(parameter_attributes(entry_f, param_index))
                    push!(parameter_attributes(wrapper_f, param_index), attr)
                end
            end
        end

        call!(builder, entry_f, wrapper_args)

        ret!(builder)

        dispose(builder)
    end

    # early-inline the original entry function into the wrapper
    push!(function_attributes(entry_f), EnumAttribute("alwaysinline", 0, JuliaContext()))
    linkage!(entry_f, LLVM.API.LLVMInternalLinkage)

    fixup_metadata!(entry_f)
    ModulePassManager() do pm
        always_inliner!(pm)
        verifier!(pm)
        run!(pm, mod)
    end

    return wrapper_f
end

# HACK: get rid of invariant.load and const TBAA metadata on loads from pointer args,
#       since storing to a stack slot violates the semantics of those attributes.
# TODO: can we emit a wrapper that doesn't violate Julia's metadata?
function fixup_metadata!(f::LLVM.Function)
    for param in parameters(f)
        if isa(llvmtype(param), LLVM.PointerType)
            # collect all uses of the pointer
            worklist = Vector{LLVM.Instruction}(user.(collect(uses(param))))
            while !isempty(worklist)
                value = popfirst!(worklist)

                # remove the invariant.load attribute
                md = metadata(value)
                if haskey(md, LLVM.MD_invariant_load)
                    delete!(md, LLVM.MD_invariant_load)
                end
                if haskey(md, LLVM.MD_tbaa)
                    delete!(md, LLVM.MD_tbaa)
                end

                # recurse on the output of some instructions
                if isa(value, LLVM.BitCastInst) ||
                   isa(value, LLVM.GetElementPtrInst) ||
                   isa(value, LLVM.AddrSpaceCastInst)
                    append!(worklist, user.(collect(uses(value))))
                end

                # IMPORTANT NOTE: if we ever want to inline functions at the LLVM level,
                # we need to recurse into call instructions here, and strip metadata from
                # called functions (see CUDAnative.jl#238).
            end
        end
    end
end

# Visits all calls to a particular intrinsic in a given LLVM module.
function visit_calls_to(visit_call::Function, name::AbstractString, mod::LLVM.Module)
    if haskey(functions(mod), name)
        func = functions(mod)[name]

        for use in uses(func)
            call = user(use)::LLVM.CallInst
            visit_call(call, func)
        end
    end
end

# Deletes all calls to a particular intrinsic in a given LLVM module.
# Returns a Boolean that tells if any calls were actually deleted.
function delete_calls_to!(name::AbstractString, mod::LLVM.Module)::Bool
    changed = false
    visit_calls_to(name, mod) do call, _
        unsafe_delete!(LLVM.parent(call), call)
        changed = true
    end
    return changed
end

# Lowers the GC intrinsics produce by the LateLowerGCFrame pass. These
# intrinsics are the last point at which we can intervene in the pipeline
# before the passes that deal with them become CPU-specific.
function lower_final_gc_intrinsics!(mod::LLVM.Module)
    ctx = global_ctx::CompilerContext
    changed = false

    # We'll start off with 'julia.gc_alloc_bytes'. This intrinsic allocates
    # store for an object, including headroom, but does not set the object's
    # tag.
    visit_calls_to("julia.gc_alloc_bytes", mod) do call, gc_alloc_bytes
        gc_alloc_bytes_ft = eltype(llvmtype(gc_alloc_bytes))::LLVM.FunctionType
        T_ret = return_type(gc_alloc_bytes_ft)::LLVM.PointerType
        T_bitcast = LLVM.PointerType(T_ret, LLVM.addrspace(T_ret))

        # Decode the call.
        ops = collect(operands(call))
        size = ops[2]

        # We need to reserve a single pointer of headroom for the tag.
        # (LateLowerGCFrame depends on us doing that.)
        headroom = Runtime.tag_size

        # Call the allocation function and bump the resulting pointer
        # so the headroom sits just in front of the returned pointer.
        let builder = Builder(JuliaContext())
            position!(builder, call)
            total_size = add!(builder, size, ConstantInt(Int32(headroom), JuliaContext()))
            ptr = call!(builder, Runtime.get(:gc_pool_alloc), [total_size])
            cast_ptr = bitcast!(builder, ptr, T_bitcast)
            bumped_ptr = gep!(builder, cast_ptr, [ConstantInt(Int32(1), JuliaContext())])
            replace_uses!(call, bumped_ptr)
            unsafe_delete!(LLVM.parent(call), call)
            dispose(builder)
        end

        changed = true
    end

    # Next up: 'julia.new_gc_frame'. This intrinsic allocates a new GC frame.
    # We'll lower it as an alloca and hope SSA construction and DCE passes
    # get rid of the alloca. This is a reasonable thing to hope for because
    # all intrinsics that may cause the GC frame to escape will be replaced by
    # nops.
    visit_calls_to("julia.new_gc_frame", mod) do call, new_gc_frame
        new_gc_frame_ft = eltype(llvmtype(new_gc_frame))::LLVM.FunctionType
        T_ret = return_type(new_gc_frame_ft)::LLVM.PointerType
        T_alloca = eltype(T_ret)

        # Decode the call.
        ops = collect(operands(call))
        size = ops[1]

        # Call the allocation function and bump the resulting pointer
        # so the headroom sits just in front of the returned pointer.
        let builder = Builder(JuliaContext())
            position!(builder, call)
            ptr = array_alloca!(builder, T_alloca, size)
            replace_uses!(call, ptr)
            unsafe_delete!(LLVM.parent(call), call)
            dispose(builder)
        end

        changed = true
    end

    # The 'julia.get_gc_frame_slot' is closely related to the previous
    # intrinisc. Specifically, 'julia.get_gc_frame_slot' gets the address of
    # a slot in the GC frame. We can simply turn this intrinsic into a GEP.
    visit_calls_to("julia.get_gc_frame_slot", mod) do call, _
        # Decode the call.
        ops = collect(operands(call))
        frame = ops[1]
        offset = ops[2]

        # Call the allocation function and bump the resulting pointer
        # so the headroom sits just in front of the returned pointer.
        let builder = Builder(JuliaContext())
            position!(builder, call)
            ptr = gep!(builder, frame, [offset])
            replace_uses!(call, ptr)
            unsafe_delete!(LLVM.parent(call), call)
            dispose(builder)
        end

        changed = true
    end

    # The 'julia.push_gc_frame' registers a GC frame with the GC. We
    # don't have a GC, so we can just delete calls to this intrinsic!
    changed |= delete_calls_to!("julia.push_gc_frame", mod)

    # The 'julia.pop_gc_frame' unregisters a GC frame with the GC, so
    # we can just delete calls to this intrinsic, too.
    changed |= delete_calls_to!("julia.pop_gc_frame", mod)

    # Ditto for 'julia.queue_gc_root'.
    changed |= delete_calls_to!("julia.queue_gc_root", mod)

    return changed
end

# lower the `julia.ptls_states` intrinsic by removing it, since it is GPU incompatible.
#
# this assumes and checks that the TLS is unused, which should be the case for most GPU code
# after lowering the GC intrinsics to TLS-less code and having run DCE.
#
# TODO: maybe don't have Julia emit actual uses of the TLS, but use intrinsics instead,
#       making it easier to remove or reimplement that functionality here.
function lower_ptls!(mod::LLVM.Module)
    ctx = global_ctx::CompilerContext
    changed = false

    if haskey(functions(mod), "julia.ptls_states")
        ptls_getter = functions(mod)["julia.ptls_states"]

        for use in uses(ptls_getter)
            val = user(use)
            if !isempty(uses(val))
                error("Thread local storage is not implemented")
            end
            unsafe_delete!(LLVM.parent(val), val)
            changed = true
        end

        @compiler_assert isempty(uses(ptls_getter)) ctx
     end

    return changed
end
