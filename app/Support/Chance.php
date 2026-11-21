<?php

namespace App\Support;

/**
 * Cryptographically-seeded coin flip used by fault injection.
 */
final class Chance
{
    /**
     * True with the given probability (0.0 → never, 1.0 → always).
     */
    public static function roll(float $probability): bool
    {
        if ($probability <= 0) {
            return false;
        }

        if ($probability >= 1) {
            return true;
        }

        return random_int(1, 10_000) <= (int) round($probability * 10_000);
    }
}
