###########################
## Create JuMP Variables ##
###########################
function add_variable!(m::MPSGEModel, S::MPSGEScalarVariable; start = 1)
    jm = jump_model(m)
    jm[name(S)] = @variable(jm,base_name = string(name(S)),start=start, lower_bound = 0)
end




function add_variable!(m::MPSGEModel, S::MPSGEIndexedVariable; start = 1)

    jm = jump_model(m)
    index = S.index

    dim = length.(index)
    
    x = JuMP.@variable(jm, [1:prod(dim)], lower_bound=0, start = start)

    for (i, ind) in enumerate(Iterators.product(index...))
        new_index = join(ind,",")
        JuMP.set_name(x[i], "$(name(S))[$new_index]")
    end

    output = JuMP.Containers.DenseAxisArray(reshape(x, Tuple(dim)), index...)
    jm[name(S)] = output
    return output

end

function add_variable!(m::MPSGEModel, S::Auxiliary)
    add_variable!(m, S; start = 0)
end

########################
## Compensated Demand ##
########################

function compensated_demands(S::ScalarSector)
    P = production(S)
    return P.compensated_demands
end

function netput_dict(S::ScalarSector)
    P = production(S)
    return P.netputs
end

function compensated_demand(S::ScalarSector,C::ScalarCommodity)
    cd = compensated_demands(S)
    netputs = netput_dict(S)
    if !haskey(netputs, C)
        return 0
    end
    sum(sum(cd[netput]) for netput∈netputs[C])
    #sum(sum(v) for (netput, v)∈cd if commodity(netput) == C; init = 0)
end


taxes(N::Netput, H::ScalarConsumer) = [tax(t) for t∈taxes(N) if tax_agent(t) == H]
function total_tax(S::ScalarSector, C::ScalarCommodity, H::ScalarConsumer)
    P = production(S)
    return sum(Iterators.flatten(taxes.(P.netputs[C], Ref(H))); init = 0)
end

function tau(S::ScalarSector,H::ScalarConsumer)
    -sum(compensated_demand(S, C) * total_tax(S, C, H) * C for C∈commodities(S) if total_tax(S,C,H)!=0; init=0)
    #Taxes = taxes(S,H)
    #return -sum( compensated_demand(X,C,n)* tax * C for ((C,n),tax)∈Taxes; init=0)
end


########################
## Demands/Endowments ##
########################

function demand(H::Consumer)
    D = demands(model(H))
    return D[H]
end

function endowment(H::Consumer, C::Commodity)
    D = demand(H)
    endows = endowments(D)
    if !haskey(endows,C)
        return 0
    else
        return quantity(endows[C])
    end
end

function demand(H::Consumer, C::Commodity)
    D = demand(H)
    total_quantity = quantity(D)
    if !haskey(D.demands, C)
        return 0
    end
    d = D.demands[C]
    return quantity(d)/total_quantity * H/C * ifelse(elasticity(D) != 1, (expenditure(D)*reference_price(d)/C)^(elasticity(D)-1), 1)
end


function expenditure(D::ScalarDemand)
    total_quantity = quantity(D)
    σ = elasticity(D)
    return sum( quantity(d)/total_quantity * (commodity(d)/reference_price(d))^(1-σ) for (_,d)∈demands(D))^(1/(1-σ))
end

#################
## Constraints ##
#################

function zero_profit(S::ScalarSector)
    M = model(S)
    sum(compensated_demand(S,C)*C for C∈commodities(S)) - sum(tau(S,H) for H∈consumers(M) if tau(S,H)!=0; init=0)
end

function market_clearance(C::ScalarCommodity)
    M = model(C)
    sum(compensated_demand(S,C) * S for S∈sectors(C)) - sum( endowment(H,C) - demand(H,C) for H∈consumers(M))
end

function income_balance(H::ScalarConsumer)
    M = model(H)
    H - (sum(endowment(H,C)* C for C∈commodities(M) if endowment(H,C)!=0) - sum(tau(S,H)*S for S∈production_sectors(M) if tau(S,H)!=0; init=0))
end




"""
    solve!(m::abstract_mpsge_model; keywords)
    Function to solve the model. Triggers the build if the model hasn't been built yet.
### Example
```julia-repl
julia> solve!(m, cumulative_iteration_limit=0)
```
"""
function solve!(m::AbstractMPSGEModel; kwargs...)
    jm = jump_model(m)
    if jm===nothing
        jm = build!(m)
    end

    #JuMP.set_optimizer(jm, PATHSolver.Optimizer)

    for (k,v) in kwargs
        JuMP.set_attribute(jm, string(k), v)
    end

    JuMP.optimize!(jm)

    #return m
end