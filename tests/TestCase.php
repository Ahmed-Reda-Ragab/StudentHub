<?php

namespace Tests;

use App\Http\Middleware\PreventDuplicateSubmissions;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Illuminate\Support\Str;

abstract class TestCase extends BaseTestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        $this->withoutVite();
    }

    /**
     * Payload with a fresh idempotency token, as rendered by <x-form>.
     *
     * @param  array<string, mixed>  $data
     * @return array<string, mixed>
     */
    protected function withSubmissionToken(array $data, ?string $token = null): array
    {
        return $data + [PreventDuplicateSubmissions::FIELD => $token ?? (string) Str::uuid()];
    }
}
