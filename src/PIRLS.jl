"""
    GeneralizedLinearMixedModel

Generalized linear mixed-effects model representation

Members:

- `LMM`: a [`LinearMixedModel`]({ref}) - used for the random effects only.
- `dist`: a `UnivariateDistribution` - typically `Bernoulli()`, `Binomial()`, `Gamma()` or `Poisson()`.
- `link`: a suitable `GLM.Link` object
- `β`: the fixed-effects vector
- `θ`: covariance parameter vector
- `b`: similar to `u`, equivalent to `broadcast!(*, b, LMM.Λ, u)`
- `u`: a vector of matrices of random effects
- `u₀`: similar to `u`.  Used in the PIRLS algorithm if step-halving is necessary.
- `X`:
- `y`: the response vector
- `μ`: the mean vector
- `η`: the linear predictor
- `devresid`: vector of squared deviance residuals
- `offset`: offset₀ + `X * β`
- `offset₀`: prior offset; `T[]` is allowed
- `wrkresid`: vector of working residuals
- `wrkwt`: vector of working weights
- `wt`: vector of prior case weights, a value of `T[]` indicates equal weights.
- `devold`: scalar - the [`LaplaceDeviance`]({ref}) at `u₀`
"""

type GeneralizedLinearMixedModel{T <: AbstractFloat, D <: UnivariateDistribution, L <: Link} <: MixedModel
    LMM::LinearMixedModel{T}
    dist::D
    link::L
    β::Vector{T}
    θ::Vector{T}
    b::Vector{Matrix{T}}
    u::Vector{Matrix{T}}
    u₀::Vector{Matrix{T}}
    X::Matrix{T}
    y::Vector{T}
    μ::Vector{T}
    η::Vector{T}
    devresid::Vector{T}
    offset::Vector{T}
    offset₀::Vector{T}
    wrkresid::Vector{T}
    wrkwt::Vector{T}
    wt::Vector{T}
end

"""
    glmm(f, fr, d)
    glmm(f, fr, d, wt, l)

Args:

- `f`: a `DataFrames.Formula` describing the response, the fixed-effects and the random-effects terms
- `fr`: a `DataFrames.DataFrame` in which to evaluate `f`
- `d`: the conditional distribution family for the response
- `wt`: a vector of prior weights, use `[]` for no prior weights
- `l`: a `GLM.Link` suitable for use with `d`

Returns:
  A [`GemeralizedLinearMixedModel`]({ref}).

Notes:
  The return value is ready to be `fit!` but has not yet been fit.
"""
function glmm(f::Formula, fr::AbstractDataFrame, d::Distribution, l::Link; wt=[], offset=[])
#    if d == Binomial() && isempty(wt)
#        d = Bernoulli()
#    end
    wts = isempty(wt) ? ones(nrow(fr)) : Array(wt)
        # the weights argument is forced to be non-empty in the lmm as it will be used later
    LMM = lmm(f, fr; wt = wts)
    LMM[:θ] = LMM[:θ]   # force inflation and decomposition of LMM.A to produce LMM.R
    A, R, trms, u, y = LMM.A, LMM.R, LMM.trms, ranef(LMM), copy(model_response(LMM))
    wts = oftype(y, wts)
    kp1 = length(LMM.Λ) + 1
    X = trms[kp1]
            # zero the dimension of the fixed-effects in trms, A and R
    LMM.wttrms[kp1] = trms[kp1] = zeros((length(y), 0))
    for i in 1:kp1
        qi = size(trms[i], 2)
        A[i, kp1] = zeros((qi, 0))
        R[i, kp1] = zeros((qi, 0))
    end
    qend = size(trms[end], 2)  # should always be 1 but no harm in extracting it
    A[kp1, end] = zeros((0, qend))
    R[kp1, end] = zeros((0, qend))
            # fit a glm to the fixed-effects only
    gl = glm(X, y, d, l; wts = wts)
    r = gl.rr
    res = GeneralizedLinearMixedModel(LMM, d, l, coef(gl), LMM[:θ], deepcopy(u), u, map(zeros, u),
        X, y, r.mu, r.eta, r.devresid, copy(r.eta), oftype(y, offset), r.wrkresid, r.wrkwts,
        oftype(y, wt))
    wrkresp!(trms[end], res)
    reweight!(LMM, res.wrkwt)
    res
end

glmm(f::Formula, fr::AbstractDataFrame, d::Distribution) = glmm(f, fr, d, GLM.canonicallink(d))

lmm(m::GeneralizedLinearMixedModel) = m.LMM

Base.logdet{T}(m::GeneralizedLinearMixedModel{T}) = logdet(lmm(m))

fixef(m::GeneralizedLinearMixedModel) = m.β

"""
    LaplaceDeviance(m)

Laplace approximation to the deviance of a GLMM.  For a distribution
that does not have a scale factor this is defined as the squared length
of the conditional modes, `u`, plus the determinant of `Λ'Z'ZΛ + 1`, plus
the sum of the squared deviance residuals.

Args:

- `m`: a `GeneralizedLinearMixedModel`

Returns:
  the Laplace approximation to the deviance of `m`
"""
function LaplaceDeviance{T}(m::GeneralizedLinearMixedModel{T})
    s = sum(m.devresid) + T(logdet(m))
    for um in m.u, umi in um
        s += abs2(umi)
    end
    s
end

#    dd, μ, y = typeof(m.dist), m.μ, m.y
#    s =
#    if dd ≠ Binomial
#        for i in eachindex(y)
#            s -= 2 * logpdf(dd(μ[i]), y[i])
#        end
#        return s
#    end
#    n = m.wt
#    for i in eachindex(n)
#        s -= 2 * logpdf(dd(n[i], μ[i]), round(Int, y[i] * n[i]))
#    end
#    s
#end

function LaplaceDeviance!(m::GeneralizedLinearMixedModel)
    updateη!(m)
    lm = lmm(m)
    wrkresp!(lm.trms[end], m)
    reweight!(lm, m.wrkwt)
    lm[:θ] = m.θ
    LaplaceDeviance(m)
end

lowerbd(m::GeneralizedLinearMixedModel) = vcat(fill(-Inf, size(m.β)), lowerbd(m.LMM))

"""
    updateη!(m)

Update the linear predictor, `m.η`, the mean vector, `m.μ`, and associated
derivatives, variances, working residuals, working weights, etc. from the current
values of the random effects, `m.u` and `m.Λ`

Args:

- `m`: a `GeneralizedLinearMixedModel`

Returns:
   the updated `m`.
"""
function updateη!(m::GeneralizedLinearMixedModel)
    η, lm, b, offset, u = m.η, m.LMM, m.b, m.offset, m.u
    Λ, trms = lm.Λ, lm.trms
    isempty(offset) ? fill!(η, 0) : copy!(η, offset)
    for i in eachindex(b)
        unscaledre!(η, trms[i], A_mul_B!(Λ[i], copy!(b[i], u[i])))
    end
    updateμ!(m)
end

"""
    pirls!(m)

Use Penalized Iteratively Reweighted Least Squares (PIRLS) to determine the conditional modes of the random effects

Args:

- `m`: a `GeneralizedLinearMixedModel`

Returns:
  the updated model `m`

Note:
  On entry the values of `m.u₀` and `m.devold` should correspond.
  One safe approach is to zero out `m.u₀` and evaluate devold from fixed-effects only.
"""
function pirls!{T}(m::GeneralizedLinearMixedModel{T})
    iter, maxiter, obj = 0, 100, T(-Inf)
    u₀, u = m.u₀, m.u
    for j in eachindex(u)         # start from u all zeros
        copy!(u₀[j], fill!(u[j], 0))
    end
    obj₀ = LaplaceDeviance!(m)
    while iter < maxiter
        iter += 1
        ranef!(u, m.LMM, true)    # solve for new values of u
        obj = LaplaceDeviance!(m) # update GLM vecs and evaluate Laplace approx
#        @show obj, obj₀
        nhalf = 0
        while obj > obj₀
            nhalf += 1
            if nhalf > 10
                if iter < 2
                    throw(ErrorException("number of averaging steps > 10"))
                end
                break
            end
            for i in eachindex(u)
                ui = u[i]
                ui₀ = u₀[i]
                for j in eachindex(ui)
                    ui[j] += ui₀[j]
                    ui[j] *= 0.5
                end
            end
            obj = LaplaceDeviance!(m)
#            @show obj, nhalf
        end
        if isapprox(obj, obj₀; atol = 0.0001)
            break
        end
        for i in eachindex(u)
            copy!(u₀[i], u[i])
        end
        obj₀ = obj
    end
    obj
end

"""
    m[:βθ] = v

Set the parameter vector - the concatenation of the fixed-effects, `β`,
and the covariance parameter, `θ` - and reset the random effects to zero.

The reason for setting the random effects to zero is so that the evaluation
of the deviance is reproducible.  If the starting points for `u` are more-or-less
random then the final value of the objective in PIRLS will not be reproducible and
this can cause problems with the nonlinear optimizers.

Args:

- `m`: a `GeneralizedLinearMixedModel`
- `v`: the parameter vector to install
- `k`: a `Symbol` - the only accepted value is `:βθ`

Returns:
  `m` in a form suitable for passing to [`pirls!`]({ref})
"""
function Base.setindex!{T <: AbstractFloat}(m::GeneralizedLinearMixedModel, v::Vector{T}, k::Symbol)
    if k ≠ :βθ
        throw(ArgumentError(":βθ is the only key allowed for a GeneralizedLinearMixedModel"))
    end
    β, lm, u, u₀, offset, offset₀ = m.β, m.LMM, m.u, m.u₀, m.offset, m.offset₀
    lb = length(β)
    copy!(m.θ, sub(v, (lb + 1):length(v)))
    copy!(β, sub(v, 1:lb))
    if isempty(offset₀)
        A_mul_B!(offset, m.X, β)
    else
        BLAS.gemv!('N', one(T), m.X, β, one(T), copy!(offset, offset₀))
    end
    m
end

sdest{T <: AbstractFloat}(m::GeneralizedLinearMixedModel{T}) = one(T)

"""
    fit!(m[, verbose = false])

Optimize the objective of a `GeneralizedLinearMixedModel` using an NLopt optimizer.

Args:

- `m`: a [`GeneralizedLinearMixedModel`]({ref})
- `verbose`: `Bool` indicating if information on iterations should be printed, Defaults to `false`

Named Args:

- `optimizer`: `Symbol` form of the name of a derivative-free optimizer in `NLopt` that allows for
  box constraints.  Defaults to `:LN_BOBYQA`
"""
function StatsBase.fit!(m::GeneralizedLinearMixedModel, verbose::Bool=false, optimizer::Symbol=:LN_BOBYQA)
    β, lm = m.β, lmm(m)
    βΘ = vcat(β, lm[:θ])
    opt = NLopt.Opt(optimizer, length(βΘ))
    NLopt.ftol_rel!(opt, 1e-12)   # relative criterion on deviance
    NLopt.ftol_abs!(opt, 1e-8)    # absolute criterion on deviance
    NLopt.xtol_abs!(opt, 1e-10)   # criterion on parameter value changes
    NLopt.lower_bounds!(opt, vcat(-Inf * ones(β), lowerbd(lm)))
    feval = 0
    function obj(x::Vector{Float64}, g::Vector{Float64})
        if length(g) ≠ 0
            error("gradient not defined for this model")
        end
        feval += 1
        m[:βθ] = x
        pirls!(m)
    end
    if verbose
        function vobj(x::Vector{Float64}, g::Vector{Float64})
            if length(g) ≠ 0
                error("gradient not defined for this model")
            end
            feval += 1
            m[:βθ] = x
            val = pirls!(m)
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
    fmin, xmin, ret = NLopt.optimize(opt, βΘ)
    ## very small parameter values often should be set to zero
#    xmin1 = copy(xmin)
#    modified = false
#    for i in eachindex(xmin1)
#        if 0. < abs(xmin1[i]) < 1.e-5
#            modified = true
#            xmin1[i] = 0.
#        end
#    end
#    if modified  # branch not tested
#        m[:θ] = xmin1
#        ff = objective(m)
#        if ff ≤ (fmin + 1.e-5)  # zero components if increase in objective is negligible
#            fmin = ff
#            copy!(xmin,xmin1)
#        else
#            m[:θ] = xmin
#        end
#    end
    m.LMM.opt = OptSummary(βΘ,xmin,fmin,feval,optimizer)
    if verbose
        println(ret)
    end
    m
end

function VarCorr(m::GeneralizedLinearMixedModel)
    Λ, trms = m.LMM.Λ, unwttrms(m.LMM)
    VarCorr(Λ, [string(trms[i].fnm) for i in eachindex(Λ)],
        [trms[i].cnms for i in eachindex(Λ)], 1.)
end

function Base.show{T,D,L}(io::IO, m::GeneralizedLinearMixedModel{T,D,L}) # not tested
    println(io, "Generalized Linear Mixed Model fit by minimizing the Laplace approximation to the deviance")
    println(io, string("  Distribution: ", D))
    println(io, string("  Link: ", L))
    println(io, string("  deviance: ", LaplaceDeviance(m)))
    println(io); println(io)

    show(io,VarCorr(m))

    gl = grplevels(lmm(m))
    @printf(io," Number of obs: %d; levels of grouping factors: %d", length(m.offset), gl[1])
    for l in gl[2:end] @printf(io, ", %d", l) end
    println(io)
    println(io, "\n  Fixed-effects parameters:\n")
    show(io, coeftable(m))
end

varest{T <: AbstractFloat}(m::GeneralizedLinearMixedModel{T}) = one(T)
