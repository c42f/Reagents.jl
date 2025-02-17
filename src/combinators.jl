struct Sequence{Outer<:Reagent,Inner<:Reagent} <: Reagent
    outer::Outer
    inner::Inner
end

then(r::Sequence, actr::Reactable) = then(r.outer, then(r.inner, actr))
then(r::Reagent, actr::Reactable) = Reactor(r, actr)
then(::Identity, actr::Reactable) = actr

Reagents.Reagent(::Commit) = Identity()
Reagents.Reagent(actr::Reactor) = actr.reagent ⨟ Reagent(actr.continuation)

hascas(::Identity) = false

struct Choice{R1<:Reagent,R2<:Reagent} <: Reagent
    r1::R1
    r2::R2
end

hascas(r::Choice) = hascas(r.r1) || hascas(r.r2)

_maysync(r::Reagent) = maysync(then(r, Commit()))
_hascas(r::Reagent) = hascas(then(r, Commit()))

function tryreact!(actr::Reactor{<:Choice}, a, rx::Reaction, offer::Union{Offer,Nothing})
    (; r1, r2) = actr.reagent
    ans1 = tryreact!(then(r1, actr.continuation), a, rx, offer)
    ans1 isa Failure || return ans1
    if offer === nothing
        if _maysync(r1) && _hascas(r2)
            # If the first branch may synchronize, and the second branch has a
            # CAS, we need to simultaneously rescind the offer *and* commit the
            # CASes.
            return Block()
        end
    end
    ans2 = tryreact!(then(r2, actr.continuation), a, rx, offer)
    ans2 isa Failure || return ans2
    if ans1 isa Retry
        return Retry()
    else
        return ans2
    end
end

struct Both{R1<:Reagent,R2<:Reagent} <: Reagent
    r1::R1
    r2::R2
end

hascas(r::Both) = hascas(r.r1) || hascas(r.r2)

function then(r::Both, actr::Reactable)
    (; r1, r2) = r
    function tee1(x)
        function tee2(y1)
            zip12(y2) = Return((y1, y2))
            return Return(x) ⨟ r2 ⨟ Computed(zip12)
        end
        return Return(x) ⨟ r1 ⨟ Computed(tee2)
    end
    return then(Computed(tee1), actr)
end

Base.:∘(inner::Reagent, outer::Sequence) = (inner ∘ outer.inner) ∘ outer.outer
Base.:∘(inner::Reagent, outer::Reagent) = Sequence(outer, inner)

# `|` could be a bit misleading since `Choice` is rather `xor`
Base.:|(r1::Reagent, r2::Reagent) = Choice(r1, r2)
Base.:&(r1::Reagent, r2::Reagent) = Both(r1, r2)

#=
Base.:+(r1::Reagent, r2::Reagent) = Choice(r1, r2)
Base.:>>(r1::Reagent, r2::Reagent) = r2 ∘ r1
Base.:*(r1::Reagent, r2::Reagent) = Both(r1, r2)
=#

struct UntilBegin{R<:Reactor} <: Reagent
    loop::R
end

hascas(r::UntilBegin) = hascas(r.loop)

struct UntilEnd{F,R<:Reactable} <: Reagent
    f::F
    continuation::R  # used only for `hascas`
end

hascas(r::UntilEnd) = hascas(r.continuation)

struct UntilBreak{T,Rx<:Reaction}
    value::T
    rx::Rx
end

then(r::Until, actr::Reactable) =
    then(UntilBegin(then(r.reagent, then(UntilEnd(r.f, actr), Commit()))), actr)

function tryreact!(
    actr::Reactor{<:UntilBegin},
    a,
    rx::Reaction,
    offer::Union{Offer,Nothing},
)
    (; loop) = actr.reagent
    while true
        ans = tryreact!(loop, a, Reaction(), nothing)
        if ans isa UntilBreak
            return tryreact!(actr.continuation, ans.value, combine(rx, ans.rx), offer)
        elseif ans isa Block
            error("`Until(f, reagent)` does not support blocking `reagent`")
        elseif ans isa Failure
            GC.safepoint()
            # TODO: backoff
        else
            ans::Nothing
        end
    end
end

function tryreact!(actr::Reactor{<:UntilEnd}, a, rx::Reaction, offer::Union{Offer,Nothing})
    (; f) = actr.reagent
    b = f(a)
    if b === nothing
        # Commit the reaction
        return tryreact!(actr.continuation, nothing, rx, offer)
    else
        return UntilBreak(b, rx)
    end
end
