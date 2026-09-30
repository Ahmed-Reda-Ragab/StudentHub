<?php

namespace Tests\Unit;

use App\Support\WhatsApp\WhatsAppLinkBuilder;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

class WhatsAppLinkBuilderTest extends TestCase
{
    /**
     * @return array<string, array{string, string}>
     */
    public static function phones(): array
    {
        return [
            'egyptian local' => ['01012345678', '201012345678'],
            'with spaces and dashes' => ['010 1234-5678', '201012345678'],
            'plus international' => ['+201012345678', '201012345678'],
            'double zero international' => ['00201012345678', '201012345678'],
            'foreign plus' => ['+966501234567', '966501234567'],
            'already has country code' => ['201012345678', '201012345678'],
            'missing leading zero' => ['1012345678', '201012345678'],
        ];
    }

    #[DataProvider('phones')]
    public function test_it_normalizes_phone_numbers(string $input, string $expected): void
    {
        $this->assertSame($expected, (new WhatsAppLinkBuilder('20'))->normalizePhone($input));
    }

    public function test_it_builds_an_encoded_wa_me_url(): void
    {
        $url = (new WhatsAppLinkBuilder('20'))->url('01012345678', "أهلاً\nيا أحمد");

        $this->assertSame('https://wa.me/201012345678?text='.rawurlencode("أهلاً\nيا أحمد"), $url);
    }
}
