using CUDAdrv, CUDAnative, Test, Statistics

include("utils.jl")

include("array-expansion.jl")
include("array-features.jl")
include("array-reduction.jl")
include("arrays.jl")
include("binary-tree.jl")
include("bitvector.jl")
include("linked-list.jl")
include("matrix.jl")
include("ssa-opt.jl")
include("static-arrays.jl")
include("stream-queries.jl")
include("genetic-algorithm.jl")

results = run_benchmarks()
# Print the results to the terminal.
println(results)

gc_tags = [t for t in benchmark_tags if startswith(t, "gc")]

# Also write them to a CSV for further analysis.
open("strategies.csv", "w") do file
    write(file, "benchmark,nogc,gc,gc-shared,bump,bump-pinned,nogc-ratio,gc-ratio,gc-shared-ratio,bump-ratio,bump-pinned-ratio\n")
    all_results = []
    function write_line(key, results)
        if length(all_results) == 0
            all_results = [Float64[] for _ in results]
        end
        write(file, "$key,$(join(results, ','))\n")
        for (l, val) in zip(all_results, results)
            push!(l, val)
        end
    end

    for key in sort(collect(keys(results)))
        runs = results[key]
        gc_time = runs["gc"] / 1e6
        gc_shared_time = runs["gc-shared"] / 1e6
        nogc_time = runs["nogc"] / 1e6
        bump_time = runs["bump"] / 1e6
        bump_pinned_time = runs["bump-pinned"] / 1e6
        gc_ratio = gc_time / nogc_time
        gc_shared_ratio = gc_shared_time / nogc_time
        bump_ratio = bump_time / nogc_time
        bump_pinned_ratio = bump_pinned_time / nogc_time
        write_line(key, [nogc_time, gc_time, gc_shared_time, bump_time, bump_pinned_time, 1.0, gc_ratio, gc_shared_ratio, bump_ratio, bump_pinned_ratio])
    end
    write_line("mean", mean.(all_results))
end

open("gc-heap-sizes.csv", "w") do file
    ratio_tags = [t * "-ratio" for t in gc_tags]
    write(file, "benchmark,$(join(gc_tags, ',')),$(join(ratio_tags, ','))\n")
    all_times = [[] for t in gc_tags]
    all_normalized_times = [[] for t in gc_tags]
    for key in sort(collect(keys(results)))
        runs = results[key]
        times = [runs[t] / 1e6 for t in gc_tags]
        for (l, val) in zip(all_times, times)
            push!(l, val)
        end
        normalized_times = [runs[t] / runs["gc"] for t in gc_tags]
        for (l, val) in zip(all_normalized_times, normalized_times)
            push!(l, val)
        end
        write(file, "$key,$(join(times, ',')),$(join(normalized_times, ','))\n")
    end
    write(file, "mean,$(join(map(mean, all_times), ',')),$(join(map(mean, all_normalized_times), ','))\n")
end

open("gc-heap-sizes-summary.csv", "w") do file
    write(file, "heap,mean-opt,mean-shared\n")
    shared = Dict()
    sizes = Dict()
    for tag in gc_tags
        shared[tag] = false
        sizes[tag] = 60.0
        for part in split(tag, "-")
            if endswith(part, "mb")
                sizes[tag] = parse(Float64, part[1:end - 2])
            elseif part == "shared"
                shared[tag] = true
            end
        end
    end

    all_normalized_times = [[] for t in gc_tags]
    for key in sort(collect(keys(results)))
        runs = results[key]
        normalized_times = [runs[t] / runs["gc"] for t in gc_tags]
        for (l, val) in zip(all_normalized_times, normalized_times)
            push!(l, val)
        end
    end

    unique_sizes = sort(unique(values(sizes)))
    data = zeros(Float64, (2, length(unique_sizes)))
    for (tag, vals) in zip(gc_tags, all_normalized_times)
        if shared[tag]
            shared_index = 2
        else
            shared_index = 1
        end
        size_index = indexin(sizes[tag], unique_sizes)[1]
        data[shared_index, size_index] = mean(vals)
    end
    for i in 1:length(unique_sizes)
        write(file, "$(unique_sizes[i]),$(data[1, i]),$(data[2, i])\n")
    end
end