"""
    OptSummary

Summary of an `NLopt` optimization

Members:

- `initial`: a copy of the initial parameter values in the optimization
- `final`: a copy of the final parameter values from the optimization
- `fmin`: the final value of the objective
- `feval`: the number of function evaluations
- `optimizer`: the name of the optimizer used, as a `Symbol`
"""
type OptSummary
    initial::Vector{Float64}
    final::Vector{Float64}
    fmin::Float64
    feval::Int
    optimizer::Symbol
end
function OptSummary(initial::Vector{Float64},optimizer::Symbol)
    OptSummary(initial,initial,Inf,-1,optimizer)
end

"""
    LinearMixedModel

Linear mixed-effects model representation

Members:

- `mf`: the model frame, mostly used to get the `terms` component for labelling fixed effects
- `wttrms`: a length `nt` vector of weighted model matrices. The last two elements are `X` and `y`.
- `trms`: a vector of unweighted model matrices.  If `isempty(sqrtwts)` the same object as `wttrms`
- `Λ`: a length `nt - 2` vector of lower triangular matrices
- `sqrtwts`: the [`Diagonal`]({ref}) matrix of the square roots of the case weights.  Allowed to be size 0
- `A`: an `nt × nt` symmetric matrix of matrices representing `hcat(Z,X,y)'hcat(Z,X,y)`
- `R`: a `nt × nt` matrix of matrices - the upper Cholesky factor of `Λ'AΛ+I`
- `opt`: an [`OptSummary`]({ref}) object
"""
type LinearMixedModel{T} <: MixedModel
    mf::ModelFrame
    wttrms:: Vector
    trms::Vector
    sqrtwts::Diagonal{T}
    Λ::Vector{LowerTriangular{T,Matrix{T}}}
    A::Matrix        # symmetric cross-product blocks (upper triangle)
    R::Matrix        # right Cholesky factor in blocks.
    opt::OptSummary
end

function LinearMixedModel{T}(
    mf::ModelFrame,
    Rem::Vector,
    Λ::Vector{LowerTriangular{T,Matrix{T}}},
    X::AbstractMatrix{T},
    y::Vector{T},
    wts::Vector{T}
    )
    if !all(x -> isa(x, ReMat), Rem)
        throw(ArgumentError("Elements of Rem should be ReMat's"))
    end
    n, p = size(X)
    if any(t -> size(t, 1) ≠ n, Rem) || length(y) ≠ n
        throw(DimensionMismatch("n not consistent"))
    end
    k = length(Rem)
    if length(Λ) ≠ k || !all(i -> chksz(Rem[i], Λ[i]), 1:k)
        throw(DimensionMismatch("Rem and Λ"))
    end
    trms = push!(convert(Vector{Any}, Rem), X)
    push!(trms, reshape(y, (length(y), 1)))
    optsum = OptSummary(mapreduce(x -> x[:θ], vcat, Λ), :None)
    sqrtwts = Diagonal(map(sqrt, wts))
    wttrms =  isempty(sqrtwts) ? trms :
        size(sqrtwts, 2) == n ? [sqrtwts * t for t in trms] :
        throw(DimensionMismatch("length(wts) must be 0 or length(y)"))
    A, R = generateAR(wttrms)
    LinearMixedModel(mf, wttrms, trms, sqrtwts, Λ, A, R, optsum)
end

function generateAR(trms)
    nt = length(trms)
    A, R = cell(nt, nt), cell(nt, nt)
    for j in 1:nt, i in 1:j
        A[i, j] = densify(trms[i]'trms[j])
        R[i, j] = copy(A[i, j])
    end
    for j in 2:nt
        if isa(R[j, j], Diagonal) || isa(R[j, j], HBlkDiag)
            for i in 1:(j - 1)     # check for fill-in
                if !isdiag(A[i, j]'A[i, j])
                    for k in j:nt
                        R[j, k] = full(R[j, k])
                    end
                end
            end
        end
    end
    A, R
end

"""
    lmm(form, frm)
    lmm(form, frm; weights = wts)

Args:

- `form`: a `DataFrames:Formula` containing fixed-effects and random-effects terms
- `frm`: a `DataFrame` in which to evaluate `form`
- `weights`: an optional vector of prior weights in the model.  Defaults to unit weights.

Returns:
  A [`LinearMixedModel`]({ref}).

Notes:
  The return value is ready to be `fit!` but has not yet been fit.
"""
function lmm(f::Formula, fr::AbstractDataFrame; wt::Vector = [])
    mf = ModelFrame(f, fr)
    X = ModelMatrix(mf)
    y = convert(Vector{eltype(X.m)}, DataFrames.model_response(mf))
                                        # process the random-effects terms
    retrms = filter(x->Meta.isexpr(x, :call) && x.args[1] == :|, mf.terms.terms)
    if isempty(retrms)
        throw(ArgumentError("$f has no random-effects terms"))
    end
    re = sort!([remat(e, mf.df) for e in retrms]; by = nlevs, rev = true)
    LinearMixedModel(mf, re, map(LT,re), X.m, y, oftype(y, wt))
end

unwttrms(m::LinearMixedModel) = isempty(m.sqrtwts) ? m.wttrms : m.trms

"""
    fit!(m[, verbose = false]; optimizer = :LN_BOBYQA)

Optimize the objective of a `LinearMixedModel` using an `NLopt` optimizer.

Args:

- `m`: a [`LinearMixedModel`]({ref})
- `verbose`: `Bool` indicating if information on iterations should be printed, Defaults to `false`

Named Args:

- `optimizer`: `Symbol` form of the name of a derivative-free optimizer in `NLopt` that allows for
  box constraints.  Defaults to `:LN_BOBYQA`
"""
function StatsBase.fit!(m::LinearMixedModel, verbose::Bool=false, optimizer::Symbol=:LN_BOBYQA)
    th = m[:θ]
    k = length(th)
    opt = NLopt.Opt(optimizer, k)
    NLopt.ftol_rel!(opt, 1e-12)   # relative criterion on deviance
    NLopt.ftol_abs!(opt, 1e-8)    # absolute criterion on deviance
    NLopt.xtol_abs!(opt, 1e-10)   # criterion on parameter value changes
    NLopt.lower_bounds!(opt, lowerbd(m))
    feval = 0
    function obj(x::Vector{Float64}, g::Vector{Float64})
        length(g) == 0 || error("gradient not defined")
        feval += 1
        m[:θ] = x
        objective(m)
    end
    if verbose
        function vobj(x::Vector{Float64}, g::Vector{Float64})
            length(g) == 0 || error("gradient not defined")
            feval += 1
            m[:θ] = x
            val = objective(m)
            print("f_$feval: $(round(val,5)), [")
            showcompact(x[1])
            for i in 2:length(x) print(","); showcompact(x[i]) end
            println("]")
            val
        end
        NLopt.min_objective!(opt, vobj)
    else
        NLopt.min_objective!(opt, obj)
    end
    fmin, xmin, ret = NLopt.optimize(opt, th)
    ## very small parameter values often should be set to zero
    xmin1 = copy(xmin)
    modified = false
    for i in eachindex(xmin1)
        if 0. < abs(xmin1[i]) < 1.e-5
            modified = true
            xmin1[i] = 0.
        end
    end
    if modified  # branch not tested
        m[:θ] = xmin1
        ff = objective(m)
        if ff ≤ (fmin + 1.e-5)  # zero components if increase in objective is negligible
            fmin = ff
            copy!(xmin,xmin1)
        else
            m[:θ] = xmin
        end
    end
    m.opt = OptSummary(th,xmin,fmin,feval,optimizer)
    if verbose
        println(ret)
    end
    m
end

"""
    objective(m)

Args:

- `m`: a `LinearMixedModel` object

Returns:
  Negative twice the log-likelihood of model `m`
"""
objective(m::LinearMixedModel) = logdet(m) + nobs(m) * (1. + log(2π * varest(m)))

"""
    fixef!(v, m)

Overwrite `v` with the fixed-effects coefficients of model `m`

Args:

- `v`: a `Vector` of length `p`, the number of fixed-effects parameters
- `m`: a `LinearMixedModel`

Returns:
  `v` with its contents overwritten by the fixed-effects parameters
"""
function fixef!(v, m::LinearMixedModel)
    if !isfit(m)
        throw(ArgumentError("Model m has not been fit"))
    end
    Base.LinAlg.A_ldiv_B!(feR(m), copy!(v, m.R[end - 1, end]))
end

"""
    fixef(m)

Args:

- `m`: a `LinearMixedModel`

Returns:
  A `Vector` of estimates of the fixed-effects parameters of `m`
"""
function fixef(m::LinearMixedModel)
    length(m.trms) == length(m.Λ) + 1 && return zeros(0)
    vec(feR(m) \ m.R[end - 1, end])
end

"""
    df(m)
Args:

- `m`: a `LinearMixedModel`

Returns:
 Number of parameters in the model.
"""
StatsBase.df(m::LinearMixedModel) = size(m.wttrms[end - 1], 2) + length(m[:θ]) + 1

function Base.size(m::LinearMixedModel)
    k = length(m.Λ)
    trms = m.wttrms
    q = sum([size(trms[j], 2) for j in 1:k])
    n, p = size(trms[k + 1])
    n, p, q, k
end

"""
    sdest(m)

Args:

- `m`: a `LinearMixedModel` object

Returns:
  The scalar, `s`, the estimate of σ, the standard deviation of the per-observation noise
"""
sdest(m::LinearMixedModel) = sqrtpwrss(m)/√nobs(m)

"""
    sqrtpwrss(m)

Returns the square root of the penalized residual sum-of-squares, which is the bottom right block of `m.R`, as a scalar

Args:

- `m`: a `LinearMixedModel`
"""
sqrtpwrss(m::LinearMixedModel) = m.R[end,end][1]

"""
    varest(m::LinearMixedModel)

Args:

- `m`: a `LinearMixedModel`

Returns:
 The scalar, s², the estimate of σ², the variance of the conditional distribution of Y given B
"""
varest(m::LinearMixedModel) = pwrss(m)/nobs(m)

"""
    pwrss(m::LinearMixedModel)

Args:

- `m`: a `LinearMixedModel`

Returns:
  The penalized residual sum-of-squares, a scalar.
"""
pwrss(m::LinearMixedModel) = abs2(sqrtpwrss(m))

"""
    chol2cor(L)

Args:

- `L`: a `LowerTriangular` matrix

Returns:
 The correlation matrix (symmetric, positive definite with unit diagonal) corresponding to `L * L'`
"""
function chol2cor(L::LowerTriangular)
    size(L, 1) == 1 && return ones(1, 1)
    res = L * L'
    d = [inv(sqrt(res[i, i])) for i in 1:size(res, 1)]
    scale!(d, scale!(res, d))
end

Base.cor(m::LinearMixedModel) = map(chol2cor, m.Λ)

function StatsBase.deviance(m::LinearMixedModel)
    isfit(m) || error("Model has not been fit")
    objective(m)
end

"""
    isfit(m)

check if a model has been fit.

Args:

- `m`; a `LinearMixedModel`

Returns:
  A logical value indicating if the model has been fit.
"""
isfit(m::LinearMixedModel) = m.opt.fmin < Inf

"""
    lrt(mods...)

Perform sequential likelihood ratio tests on a sequence of models.

Args:

- `mods`: Two or more `LinearMixedModel` that have been fit.  They should be fits of
  the same response

Results:
  A `DataFrame` containing information on the likelihood ratio tests.
"""
function lrt(mods::LinearMixedModel...) # not tested
    if (nm = length(mods)) <= 1
        throw(ArgumentError("at least two models are required for a likelihood ratio test"))
    end
    m1 = mods[1]
    n = nobs(m1)
    for i in 2:nm
        if nobs(mods[i]) != n
            throw(ArgumentError("number of observations must be constant across models"))
        end
    end
    mods = mods[sortperm([df(m)::Int for m in mods])]
    degf = Int[df(m) for m in mods]
    dev = [deviance(m)::Float64 for m in mods]
    csqr = unshift!([(dev[i-1]-dev[i])::Float64 for i in 2:nm],NaN)
    pval = unshift!([ccdf(Chisq(degf[i]-degf[i-1]),csqr[i])::Float64 for i in 2:nm],NaN)
    DataFrame(Df = degf, Deviance = dev, Chisq=csqr,pval=pval)
end


"""
    reweight!(m, wts)

Update `m.sqrtwts` from `wts` and `m.wttrms` from `m.trms`.  Recompute `m.A`

Args:

- `m`: a `MixedModel`
- `wts`: a non-negative vector of weights

Returns:
`m` with the products in `m.A` reweighted
"""
function reweight!{T}(m::LinearMixedModel{T}, wts::Vector{T})
    A, wttrms, trms, sqrtwts = m.A, m.wttrms, m.trms, m.sqrtwts
    d = sqrtwts.diag
    if length(wts) ≠ length(d)
        throw(DimensionMismatch("length(wts) = $(length(wts)), should be $(length(d))"))
    end
    for i in eachindex(wts)
        d[i] = sqrt(wts[i])
    end
    for j in eachindex(trms)
        A_mul_B!(sqrtwts, copy!(wttrms[j], trms[j]))
    end
    for j in 1:size(A, 2), i in 1:j
        Ac_mul_B!(A[i, j], wttrms[i], wttrms[j])
    end
    m
end

function Base.show(io::IO, m::LinearMixedModel) # not tested
    if !isfit(m)
        warn("Model has not been fit")
        return nothing
    end
    n,p,q,k = size(m)
    @printf(io, "Linear mixed model fit by maximum likelihood")
    println(io)

    oo = objective(m)
#    if REML
#        @printf(io, " REML criterion: %f", oo)
#    else
# FIXME: Use `showoff` here to align better
        @printf(io, " logLik: %f, deviance: %f, AIC: %f, BIC: %f",-oo/2.,oo, AIC(m),BIC(m))
#    end
    println(io); println(io)

    show(io,VarCorr(m))

    gl = grplevels(m)
    @printf(io," Number of obs: %d; levels of grouping factors: %d", n, gl[1])
    for l in gl[2:end] @printf(io, ", %d", l) end
    println(io)
    @printf(io,"\n  Fixed-effects parameters:\n")
    show(io,coeftable(m))
end

"""
    VarCorr

An encapsulation of information on the fitted random-effects
variance-covariance matrices.

Members:

- `Λ`: the vector of lower triangular matrices from the `MixedModel`
- `fnms`: a `Vector{ASCIIString}` of grouping factor names
- `cnms`: a `Vector{Vector{ASCIIString}}` of column names
- `s`: the estimate of σ, the standard deviation of the per-observation noise

The main purpose is to isolate the logic in the show method.
"""
type VarCorr
    Λ::Vector
    fnms::Vector
    cnms::Vector
    s::Float64
    function VarCorr(Λ::Vector, fnms::Vector, cnms::Vector, s::Number)
        length(fnms) == length(cnms) == length(Λ) || throw(DimensionMismatch(""))
        s >= 0 || error("s must be non-negative")
        new(Λ, fnms, cnms, s)
    end
end
function VarCorr(m::LinearMixedModel)
    Λ, trms = m.Λ, unwttrms(m)
    VarCorr(Λ,
            [string(trms[i].fnm) for i in eachindex(Λ)],
            [trms[i].cnms for i in eachindex(Λ)],
            sdest(m))
end

function Base.show(io::IO,vc::VarCorr)
    fnms = vcat(vc.fnms,"Residual")
    nmwd = maximum(map(strwidth, fnms))
    write(io, "Variance components:\n")
    stdm = vc.s*push!([rowlengths(λ) for λ in vc.Λ],[1.])
    tt = vcat(stdm...)
    vi = showoff(abs2(tt), :plain)
    si = showoff(tt, :plain)
    varwd = 1 + max(length("Variance"), maximum(map(strwidth, vi)))
    stdwd = 1 + max(length("Std.Dev."), maximum(map(strwidth, si)))
    write(io, " "^(2+nmwd))
    write(io, Base.cpad("Variance", varwd))
    write(io, Base.cpad("Std.Dev.", stdwd))
    any(s -> length(s) > 1,stdm) && write(io,"  Corr.")
    println(io)
    cor = [chol2cor(λ) for λ in vc.Λ]
    ind = 1
    for i in 1:length(fnms)
        stdmi = stdm[i]
        write(io, ' ')
        write(io, rpad(fnms[i], nmwd))
        write(io, lpad(vi[ind], varwd))
        write(io, lpad(si[ind], stdwd))
        ind += 1
        println(io)
        for j in 2:length(stdmi)
            write(io, lpad(vi[ind], varwd + nmwd + 1))
            write(io, lpad(si[ind], stdwd))
            ind += 1
            for k in 1:(j-1)
                @printf(io, "%6.2f", cor[i][j, k])
            end
            println(io)
        end
    end
end
