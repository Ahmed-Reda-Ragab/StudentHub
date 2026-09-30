<?php

namespace App\Support\WhatsApp;

use App\Enums\SubscriptionStatus;
use App\Models\Student;

/**
 * Builds click-to-chat links (wa.me) — no API, the user presses "send" in WhatsApp.
 * Kept isolated so it can later be swapped for WhatsApp Cloud API / Twilio delivery.
 */
class WhatsAppLinkBuilder
{
    public function __construct(
        private readonly string $defaultCountryCode = '20',
        private readonly string $baseUrl = 'https://wa.me',
    ) {}

    /**
     * 01012345678 → 201012345678, +20 10… / 0020 10… → 2010…
     */
    public function normalizePhone(string $phone): string
    {
        $phone = trim($phone);
        $isInternational = str_starts_with($phone, '+') || str_starts_with($phone, '00');
        $digits = preg_replace('/\D+/', '', $phone);

        if ($isInternational) {
            return str_starts_with($phone, '+') ? $digits : substr($digits, 2);
        }

        if (str_starts_with($digits, '0')) {
            return $this->defaultCountryCode.substr($digits, 1);
        }

        // Already carries the country code (e.g. 2010xxxxxxxx) — long enough to be international.
        if (str_starts_with($digits, $this->defaultCountryCode) && strlen($digits) > 10) {
            return $digits;
        }

        return $this->defaultCountryCode.$digits;
    }

    public function url(string $phone, string $message): string
    {
        return sprintf('%s/%s?text=%s', rtrim($this->baseUrl, '/'), $this->normalizePhone($phone), rawurlencode($message));
    }

    public function forStudent(Student $student, ?string $template = null): string
    {
        return $this->url($student->phone, $this->render($template ?? $this->defaultTemplateFor($student), $student));
    }

    /**
     * Placeholders: {name} {code} {section} {next_renewal_date} {days_left}
     */
    public function render(string $template, Student $student): string
    {
        return strtr($template, [
            '{name}' => $student->name,
            '{code}' => $student->code,
            '{section}' => $student->section,
            '{next_renewal_date}' => $student->next_renewal_date->format('d/m/Y'),
            '{days_left}' => (string) max(0, $student->daysUntilRenewal()),
        ]);
    }

    private function defaultTemplateFor(Student $student): string
    {
        return $student->status() === SubscriptionStatus::Expired
            ? __('whatsapp.templates.expired')
            : __('whatsapp.templates.upcoming');
    }
}
