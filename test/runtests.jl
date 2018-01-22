using OpenBCI_WiFi
using Base.Test
# Run tests

tic()
@time @test include("test.jl")
toc()
