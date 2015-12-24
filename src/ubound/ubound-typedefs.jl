#unum-ubound.jl

@generated function __check_Ubound{ESS,FSS}(ESSp, FSSp, lower::Unum{ESS,FSS}, upper::Unum{ESS,FSS})
  if (ESS == 0) && (FSS == 0)
    (lower > upper) && throw(ArgumentError("ubound built backwards: $(bits(a)) > $(bits(b))"))
  else
    (lower > upper) && throw(ArgumentError("ubound built backwards: $(bits(a, " ")) > $(bits(b, " "))"))
  end
end

#basic ubound type, which contains two unums, as well as some properties of ubounds
immutable Ubound{ESS,FSS} <: Utype
  lower::Unum{ESS,FSS}
  upper::Unum{ESS,FSS}

  @dev_check ESS FSS function Ubound(a, b)
    new(a, b)
  end
end
#springboard off of the inner constructor type to get this to work.  Yes, inner
#constructors in julia are a little bit confusing.
Ubound{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS}) = Ubound{ESS,FSS}(a,b)

export Ubound

#=

function __open_ubound_helper{ESS,FSS}(a::Unum{ESS,FSS}, lowbound::Bool)
  is_ulp(a) && return unum_unsafe(a)
  is_zero(a) && return sss(Unum{ESS,FSS}, lowbound ? z16 : UNUM_SIGN_MASK)
  (is_negative(a) != lowbound) ? outward_ulp(a) : inward_ulp(a)
end

#creates a open ubound from two unums, a < b, ensures it's open regardless of
#whether or not the values passed are exact.
function open_ubound{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS})
  #make sure the lower bound of b is bigger than a and vice versa.
  __check_block_open_ubound

  #match the sign masks for the case of a or b being zero.
  ulp_a = __open_ubound_helper(a, true)
  ulp_b = __open_ubound_helper(b, false)
  #avoid emitting an incorrect ubound in case ulp_a and ulp_b are identical.
  ubound_resolve(ubound_unsafe(ulp_a, ulp_b))
end
export open_ubound

#converts a Ubound into a unum, if applicable.  Otherwise, drop the ubound.
function ubound_resolve{ESS,FSS}(b::Ubound{ESS,FSS})
  #if the sign masks are not equal then we're toast - there's no way to resolve
  #this as a single unum.
  (is_negative(b.lowbound) != is_negative(b.highbound)) && return b
  #also disqualify if either one is exact.
  (is_exact(b.lowbound) || is_exact(b.highbound)) && return b
  #reorder the two based on magnitude, and copy the data.
  (smaller, bigger) = (is_negative(b.lowbound)) ? (unum_unsafe(b.highbound), unum_unsafe(b.lowbound)) : (unum_unsafe(b.lowbound), unum_unsafe(b.highbound))
  #resolve strange subnormals, if applicable.
  is_exp_zero(smaller) && (smaller = __resolve_subnormal(smaller))
  is_exp_zero(bigger) && (bigger = __resolve_subnormal(bigger))
  #one easy condition is if we're inner-zero-bounded.
  if (is_exp_zero(smaller) && is_frac_zero(smaller))
    (decode_exp(bigger) >= 0) && return b
    #check to see if the outer bound is a power of two.
    !__frac_allones(bigger.fraction, bigger.fsize) && return b
    #figure out the appropriate fsize to represent this number.
  end

  #if both are identical, then we can resolve this ubound immediately
  (b.lowbound == b.highbound) && return b.lowbound
  #cache the length of these unums
  l::Uint16 = length(b.lowbound.fraction)

    #now, find the next exact ulp for the bigger one
    bigger = __outward_exact(bigger)

    #check to see if bigger is at the boundary of two enums.
    if (bigger.fraction == 0) && (bigger.exponent == smaller.exponent + 1)
      #check to see if the smaller fraction is all ones.
      eligible = smaller.fraction == fillbits(-(smaller.fsize + 1), l)
      trim::Uint16 = 0
    elseif smaller.fsize > bigger.fsize #mask out the lower bits
      eligible = (smaller.fraction & fillbits(bigger.fsize, l)) == zeros(Uint64, l)
      trim = bigger.fsize
    else
      eligible = ((bigger.fraction & fillbits(smaller.fsize, l)) == zeros(Uint64, l))
      trim = smaller.fsize
    end
    (eligible) ? Unum{ESS,FSS}(trim, smaller.esize, smaller.flags, smaller.fraction, smaller.exponent) : b
  end

  return b

end
=#