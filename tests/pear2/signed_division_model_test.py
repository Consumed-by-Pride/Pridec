#!/usr/bin/env python3
"""Validate signed power-of-two quotient and remainder strength-reduction formulas."""

import random


def truncating_division(value: int, divisor: int) -> int:
    quotient = abs(value) // divisor
    return -quotient if value < 0 else quotient


def check_value(bits: int, value: int, shift: int) -> None:
    divisor = 1 << shift
    bias_mask = divisor - 1
    minimum = -(1 << (bits - 1))
    maximum = (1 << (bits - 1)) - 1

    sign = value >> (bits - 1)  # Arithmetic shift: -1 for negatives, 0 otherwise.
    adjusted = value + (sign & bias_mask)
    assert minimum <= adjusted <= maximum, (bits, value, divisor, adjusted)
    actual = adjusted >> shift
    expected = truncating_division(value, divisor)
    assert actual == expected, (bits, value, divisor, actual, expected)

    # Signed remainder is x - trunc(x / d) * d; the shifted product is
    # representable for every signed x and positive power-of-two d.
    remainder = value - (actual << shift)
    expected_remainder = value - (expected * divisor)
    assert remainder == expected_remainder, (bits, value, divisor, remainder, expected_remainder)
    assert abs(remainder) < divisor, (bits, value, divisor, remainder)
    assert remainder == 0 or (remainder < 0) == (value < 0), (bits, value, divisor, remainder)


def main() -> None:
    # Exhaust every value at small widths and every positive power-of-two
    # divisor representable in the signed type.
    for bits in range(3, 13):
        minimum = -(1 << (bits - 1))
        maximum = (1 << (bits - 1)) - 1
        for shift in range(1, bits - 1):
            for value in range(minimum, maximum + 1):
                check_value(bits, value, shift)

    # Sample edge and pseudorandom values for production widths with a fixed
    # seed so failures are reproducible.
    rng = random.Random(0x50454152)
    for bits in (16, 32, 64):
        minimum = -(1 << (bits - 1))
        maximum = (1 << (bits - 1)) - 1
        values = {
            minimum,
            minimum + 1,
            -65,
            -64,
            -33,
            -9,
            -8,
            -7,
            -3,
            -1,
            0,
            1,
            3,
            7,
            8,
            9,
            maximum - 1,
            maximum,
        }
        values = {value for value in values if minimum <= value <= maximum}
        values.update(rng.randint(minimum, maximum) for _ in range(2000))
        for shift in range(1, bits - 1):
            for value in values:
                check_value(bits, value, shift)

    print("PASS: signed power-of-two quotient/remainder formulas match truncation for widths 3..64")


if __name__ == "__main__":
    main()
