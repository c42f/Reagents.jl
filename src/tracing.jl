const Recalls = try
    Base.require(Base.PkgId(Base.UUID(0x30af7cf3eb4344c7afa733725b72a81e), "Recalls"))
catch
    nothing
end

istracing() = false

macro trace(args...)
    Recalls === nothing && return nothing
    quote
        if $istracing()
            $Recalls.@note($(args...),)
        end
        nothing
    end |> esc
end
# TODO: Use Preferences.jl to controll if Recalls.jl should be loaded? Since
# `args` may affect how much variables are captured in closures, the existence
# of Recalls.jl changes the program slightly.

function enable_tracing()
    if Recalls === nothing
        error(
            "Tracing requires Recalls.jl to be installed in the same environment.",
            " See: https://github.com/tkf/Recalls.jl",
        )
    end
    prev = istracing()
    @eval istracing() = true
    return prev
end

function disable_tracing()
    prev = istracing()
    @eval istracing() = false
    return prev
end

should_limit_retries() = istracing() || use_anchors() || use_retrylimit()

use_retrylimit() = false

function enable_retrylimit()
    prev = use_retrylimit()
    @eval use_retrylimit() = true
    return prev
end

function disable_retrylimit()
    prev = use_retrylimit()
    @eval use_retrylimit() = false
    return prev
end
