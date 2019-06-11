using CUDAdrv, CUDAnative, Test

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
    write(file, "benchmark,nogc,gc,gc-shared,bump,nogc-ratio,gc-ratio,gc-shared-ratio,bump-ratio\n")
    for key in sort([k for k in keys(results)])
        runs = results[key]
        median_times = BenchmarkTools.median(runs)
        gc_time = median_times["gc"].time / 1e6
        gc_shared_time = median_times["gc-shared"].time / 1e6
        nogc_time = median_times["nogc"].time / 1e6
        bump_time = median_times["bump"].time / 1e6
        gc_ratio = gc_time / nogc_time
        gc_shared_ratio = gc_shared_time / nogc_time
        bump_ratio = bump_time / nogc_time
        write(file, "$key,$nogc_time,$gc_time,$gc_shared_time,$bump_time,1,$gc_ratio,$gc_shared_ratio,$bump_ratio\n")
    end
end

open("gc-heap-sizes.csv", "w") do file
    ratio_tags = [t * "-ratio" for t in gc_tags]
    write(file, "benchmark,$(join(gc_tags, ',')),$(join(ratio_tags, ','))\n")
    for key in sort([k for k in keys(results)])
        runs = results[key]
        median_times = BenchmarkTools.median(runs)
        times = [median_times[t].time / 1e6 for t in gc_tags]
        normalized_times = [median_times[t].time / median_times["gc"].time for t in gc_tags]
        write(file, "$key,$(join(times, ',')),$(join(normalized_times, ','))\n")
    end
end
