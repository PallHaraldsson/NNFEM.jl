#= 


=#


using Revise
using Test 
using NNFEM
using PyCall
using PyPlot
using JLD2
using ADCME
using LinearAlgebra
reset_default_graph()

T = 0.005
NT = 100
Δt = T/NT
nntype = "ae_scaled"

include("nnutil.jl")

testtype = "NeuralNetwork1D"
include("NNTrussPull_Domain.jl")

prop = Dict("name"=> testtype, "rho"=> 8000.0, "E"=> 200e9, "nu"=> 0.45,
"sigmaY"=>0.3e9, "K"=>1/9*200e9, "B"=> 0.0, "A0"=> 1.0, "nn"=>post_nn)
elements = []
for i = 1:nx 
    elnodes = [i, i+1]; coords = nodes[elnodes,:];
    push!(elements, FiniteStrainTruss(coords,elnodes, prop, ngp))
end
# domain = Domain(nodes, elements, ndofs, EBC, g, FBC, fext)
@load "Data/domain1.jld2" domain
state = zeros(domain.neqs)
∂u = zeros(domain.neqs)
globdat = GlobalData(state,zeros(domain.neqs), zeros(domain.neqs),∂u, domain.neqs, gt, ft)
assembleMassMatrix!(globdat, domain)


E = prop["E"]
H0 = zeros(1,1)
H0[1,1] = E

n_data = [1,2,4,5]
losses = Array{PyObject}(undef, length(n_data))
for (i, ni) in enumerate(n_data)
    state_history, fext_history = read_data("$(@__DIR__)/Data/$ni.dat")
    losses[i] = DynamicMatLawLoss(domain, globdat, state_history, fext_history, nn,Δt)
end
loss = sum(losses)


sess = Session(); init(sess)
@show run(sess, loss)

BFGS!(sess, loss, 2000)
ADCME.save(sess, "Data/trained_nn_fem.mat")

# X, Y = prepare_strain_stress_data1D(domain)
# x = (constant(X[:,1]), constant(X[:,2]), constant(X[:,3]))
# y = squeeze(nn(x...))
# close("all")
# out = run(sess, y)
# plot(X[:,1], out,"+", label="NN")
# plot(X[:,1], Y, ".", label="Exact")
# legend()
