#!/usr/bin/env python3
"""Check exact panning over every signed 16-bit sample, MT-32 pan and polarity."""
from la32_partial import pan_factor


def check():
    triples = 0
    # Munt negates both factors of a pair for partials 4-7 in every eight;
    # the kernel's second copy negates the shifted sample for that pair.
    for polarity in (1, -1):
        for pan in range(15):
            left, right = polarity * pan_factor(pan), polarity * pan_factor(14 - pan)
            assert left + right == polarity * 8192, (polarity, pan, left, right)
            for sample in range(-32768, 32768):
                product = sample * left
                # Compare the derived right product with an independent channel
                # multiply. Do not derive it from the already-rounded left word.
                actual = (polarity * (sample << 13) - product) >> 13
                assert actual == (sample * right) >> 13, (polarity, pan, sample)
                triples += 1
    print(f'PASS exact complementary pan: {triples} signed sample/pan/polarity triples, '
          'including hard pans and the negated pair')


if __name__ == '__main__':
    check()
