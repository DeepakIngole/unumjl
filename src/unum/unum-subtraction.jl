#unit-subtraction.jl
#implements addition primitives where the vectors of the two values point in
#opposing directions.  This is organized into a separate file for convenience
#purposes (these primitives can be very large.)

doc"""
  `sub!(::Unum{ESS,FSS}, ::Unum{ESS,FSS}, ::Gnum{ESS,FSS})` takes two unums and
  subtracts them, storing the result in the third, g-layer

  `sub!(::Unum{ESS,FSS}, ::Gnum{ESS,FSS})` takes two unums and subtracts them, storing
  the result and overwriting the second, g-layer

  In both cases, a reference to the result gnum is returned.
"""
function sub!{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS}, c::Gnum{ESS,FSS})
  put_unum!(b, c)
  sub!(a, c)
end

function sub!{ESS,FSS}(a::Unum{ESS,FSS}, b::Gnum{ESS,FSS})
  additive_inverse!(b)

  add!{ESS,FSS}(a, b)

  clear_ignore_sides!(b)
  b
end

function additive_inverse!(b)
  is_nan(b) && return #lazy eval
  if is_twosided(b)
    #additive inverse them and then switch lower and upper.
    additive_inverse!(b.lower)
    additive_inverse!(b.upper)
    copy_unum!(b.upper, b.scratchpad)
    copy_unum!(b.lower, b.upper)
    copy_unum!(b.scratchpad, b.lower)
  else
    additive_inverse!(b.lower)
  end
end

@generated function __arithmetic_subtraction!{ESS,FSS,side}(a::Unum{ESS,FSS}, b::Gnum{ESS,FSS}, ::Type{Val{side}})
  quote
    if is_ulp(a)
      if is_exact(b.$side)
        copy_unum!(b.$side, b.buffer)
        copy_unum!(a, b.$side)
        __exact_arithmetic_subtraction!(b.buffer, b, Val{side})
      else
        __inexact_arithmetic_subtraction!(a, b, Val{side})
      end
    else
      __exact_arithmetic_subtraction!(a, b, Val{side})
    end
  end
end

#NB.  Because of the "switching" behavior of arithmetic subtraction, the lower operation
#leaves the original value of "lower" in the buffer.
@generated function __inexact_arithmetic_subtraction!{ESS,FSS,side}(a::Unum{ESS,FSS}, b::Gnum{ESS,FSS}, ::Type{Val{side}})
  if (side == :lower)
    quote
      promoted::Bool = false
      if is_positive(a)
        #then a is positive and b is negative.  The lower value is going to be exact(a) - exact(b); the
        #upper value is going to be ulp'd a - ulp'd b; if we are a twosided value, then the lower value
        #will influence the upper value.
        copy_unum!(b.lower, is_onesided(b) ? b.upper : b.buffer)
        make_exact!(b.lower)
        __exact_arithmetic_subtraction!(a, b, LOWER_UNUM)
        make_ulp!(b.lower)
        clear_gflags!(b.lower)
        if is_onesided(b)
          copy_unum!(a, b.buffer)
          clear_gflags!(b.upper)
          promoted = __add_ubit_frac!(b.buffer)
          #println("promoted? ", promoted, " b: ", bits(b.buffer))
          promoted && ((b.buffer.esize, b.buffer.exponent) = encode_exp(decode_exp(b.buffer) + 1))
          __exact_arithmetic_subtraction!(b.buffer, b, UPPER_UNUM)
          #before we make this an ulp, we have to figure out what the correct ubit
          #will be.
          #match_fsize!(a, b.buffer)
          #make_ulp!(b.buffer)
          #copy_unum!(b.buffer, b.upper)
          ignore_side!(b, UPPER_UNUM)
          set_twosided!(b)
        end
      else
        nan!(b)
        #then a is negative and b is positive
      end
    end
  elseif (side == :upper)
    :(nan!(b))
  end
end

#performs an exact arithmetic subtraction algorithm.  The assumption here is
#that a and b have opposite signs and are to be summed.  The sign on b is ignored.
@gen_code function __exact_arithmetic_subtraction!{ESS,FSS,side}(a::Unum{ESS,FSS}, b::Gnum{ESS,FSS}, ::Type{Val{side}})
  mesize::UInt16 = max_esize(ESS)
  mfsize::UInt16 = max_fsize(FSS)
  (FSS < 7) && (mfrac::UInt64 = mask_top(FSS))
  mexp::UInt64 = max_exponent(ESS)

  @code quote
    #for subtraction, resolving strange subnormal numbers as a first step is critical.
    is_strange_subnormal(a) && (resolve_subnormal!(a))
    is_strange_subnormal(b.$side) && (resolve_subnormal!(b.$side))

    b_exp::Int64 = decode_exp(b.$side)
    b_dev::UInt64 = is_exp_zero(b.$side) * o64
    b_ctx::Int64

    #set the exp and dev values.
    a_exp::Int64 = decode_exp(a)
    #set the deviations due to subnormality.
    a_dev::UInt64 = is_exp_zero(a) * o64
    #set the exponential contexts for both variables.
    a_ctx::Int64 = a_exp + a_dev

    #set up a placeholder for the minuend.
    shift::Int64
    vbit::UInt64
    minuend::Unum{ESS,FSS}
    scratchpad_exp::Int64
    scratchpad_dev::UInt64
    @init_sflags()

    #is a bigger?
    a_bigger = (a_exp > b_exp)
    if (a_exp == b_exp)
      a_bigger = a_bigger || ((a_dev == 0) && (b_dev != 0))
      a_bigger = a_bigger || (a_dev == b_dev) && ((a.fraction > b.$side.fraction))
    end

    if a_bigger
      #set the placeholder to the value a.
      #since we're not going to cross zero, we have to "puff up" b if it's an ulp.
      promoted::Bool = __add_ubit_frac!(b.$side)
      b_exp += promoted * 1
      b_dev = b_dev & (o64 - (promoted * o64))
      b_ctx = b_exp + b_dev

      minuend = a
      @preserve_sflags b copy_unum!(b.$side, b.scratchpad)
      b.scratchpad.flags = (b.scratchpad.flags & ~UNUM_SIGN_MASK) | (a.flags & UNUM_SIGN_MASK)
      #calculate shift as the difference between a and b
      shift = a_ctx - b_ctx
      #set up the virtual bit.
      vbit = (o64 - a_dev) - ((shift == z64) * (o64 - b_dev))
      scratchpad_exp = a_exp
      scratchpad_dev = a_dev
    else
      b_ctx = b_exp + b_dev
      #set the placeholder to the value b.
      minuend = b.$side
      #move the unum value to the scratchpad.
      @preserve_sflags b put_unum!(a, b, SCRATCHPAD)
      b.scratchpad.flags = (b.scratchpad.flags & ~UNUM_SIGN_MASK) | (~a.flags & UNUM_SIGN_MASK) | (b.$side.flags & UNUM_UBIT_MASK)
      #calculate the shift as the difference between a and b.
      shift = b_ctx - a_ctx
      #set up the carry bit.
      vbit = (o64 - b_dev) - ((shift == z64) * (o64 - a_dev))
      scratchpad_exp = b_exp
      scratchpad_dev = b_dev
    end

    #rightshift the scratchpad.
    (shift != 0) && __rightshift_frac_with_underflow_check!(b.scratchpad, shift)

    #do the actual subtraction.
    vbit = __carried_diff_frac!(vbit, minuend, b.scratchpad)

    if (vbit == 0) && (b.scratchpad.exponent != 0)
      if (scratchpad_exp >= min_exponent(ESS))
        #shift
        __leftshift_frac!(b.scratchpad, 1)
        #Put in the guard bit.

        scratchpad_exp -= 1
      end

      if (scratchpad_exp >= min_exponent(ESS))
        (b.scratchpad.esize, b.scratchpad.exponent) = encode_exp(scratchpad_exp)
      else
        b.scratchpad.esize = $mesize
        b.scratchpad.exponent = z64
      end
    end

    copy_unum_with_gflags!(b.scratchpad, b.$side)
  end
end

#=
###############################################################################
## multistage carried difference engine for uint64s.


################################################################################
## DIFFERENCE ALGORITHM

function __diff_ordered{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS}, _aexp::Int64, _bexp::Int64)
  #add two values, where a has a greater magnitude than b.  Both operands have
  #matching signs, either positive or negative.  At this stage, they may both
  #be ULPs.
  if (is_ulp(a) || is_ulp(b))
    __diff_ulp(a, b, _aexp, _bexp)
  else
    __diff_exact(a, b, _aexp, _bexp)
  end
end

function __diff_ulp{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS}, _aexp::Int64, _bexp::Int64)
  #a and b are ordered by magnitude and have opposing signs.

  #assign "exact" and "bound" a's
  (exact_a, bound_a) = is_ulp(a) ? (unum_unsafe(a, a.flags & ~UNUM_UBIT_MASK), __outward_exact(a)) : (a, a)
  (exact_b, bound_b) = is_ulp(b) ? (unum_unsafe(b, b.flags & ~UNUM_UBIT_MASK), __outward_exact(b)) : (b, b)
  #recalculate these values if necessary.
  _baexp::Int64 = is_ulp(a) ? decode_exp(bound_a) : _aexp
  _bbexp::Int64 = is_ulp(b) ? decode_exp(bound_b) : _bexp

  if (_aexp - _bbexp > max_fsize(FSS))
    if is_ulp(a)
      is_negative(a) && return ubound_resolve(ubound_unsafe(a, inward_ulp(exact_a)))
      return ubound_resolve(ubound_unsafe(inward_ulp(exact_a), a))
    end
    return inward_ulp(a)
  end

  #do a check to see if a is almost infinite.
  if (is_mmr(a))
    #a ubound ending in infinity can't result in an ulp unless the lower subtracted
    #value is zero, which is already tested for.
    is_mmr(b) && return open_ubound(neg_mmr(Unum{ESS,FSS}), pos_mmr(Unum{ESS,FSS}))

    if (is_negative(a))
      #exploit the fact that __exact_subtraction ignores ubits.
      return open_ubound(a, __diff_exact(a, bound_b, _aexp, _bbexp))
    else
      return open_ubound(__diff_exact(a, bound_b, _aexp, _bbexp), a)
    end
  end

  far_result = __diff_exact(magsort(bound_a, exact_b)...)
  near_result = __diff_exact(magsort(exact_a, bound_b)...)

  if is_negative(a)
    ubound_resolve(open_ubound(far_result, near_result))
  else
    ubound_resolve(open_ubound(near_result, far_result))
  end
end

#attempts to shift the fraction as far as allowed.  Returns appropriate esize
#and exponent, and the new fraction.
function __shift_many_zeros(fraction, _aexp, ESS, lastbit::UInt64 = z64)
  maxshift::Int64 = _aexp - min_exponent(ESS)
  tryshift::Int64 = leading_zeros(fraction) + 1
  leftshift::Int64 = tryshift > maxshift ? maxshift : tryshift
  fraction = lsh(fraction, leftshift)

  #tack on that last bit, if necessary.
  (lastbit != 0) && (fraction |= lsh(superone(length(fraction)),(leftshift - 1)))

  (esize, exponent) = tryshift > maxshift ? (max_esize(ESS), z64) : encode_exp(_aexp - leftshift)

  (esize, exponent, fraction)
end

#a subtraction operation where a and b are ordered such that mag(a) > mag(b)
=#

import Base.-
#binary subtraction creates a temoporary g-layer number to be destroyed immediately.
function -{ESS,FSS}(x::Unum{ESS,FSS}, y::Unum{ESS,FSS})
  temp = zero(Gnum{ESS,FSS})
  sub!(x, y, temp)
  #return the result as the appropriate data type.
  emit_data(temp)
end
#unary subtraction creates a new unum and flips it.
function -{ESS,FSS}(x::Unum{ESS,FSS})
  additiveinverse!(Unum{ESS,FSS}(x))
end
function -{ESS,FSS}(x::Gnum{ESS,FSS})
  additiveinverse!(Unum{ESS,FSS}(x))
end
