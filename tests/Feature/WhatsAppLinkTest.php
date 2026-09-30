<?php

namespace Tests\Feature;

use App\Models\Student;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class WhatsAppLinkTest extends TestCase
{
    use RefreshDatabase;

    public function test_student_link_uses_international_number_and_reminder_template(): void
    {
        $student = Student::factory()->for(User::factory())->create(['name' => 'أحمد', 'phone' => '01012345678']);

        $url = $student->whatsappUrl();
        $text = rawurldecode(parse_url($url, PHP_URL_QUERY));

        $this->assertStringStartsWith('https://wa.me/201012345678?text=', $url);
        $this->assertSame(
            "text=اهلا أحمد 👋\nمرحبا. نحب نذكرك أن اشتراكك في منصة ثناويكا انتهى أو متبقي على انتهائه ساعات قليلة ⏳\n\nتحب تجديد الاشتراك.",
            $text,
        );
    }

    public function test_expired_students_get_the_same_reminder(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-11-05 10:00', 'Africa/Cairo'));

        $student = Student::factory()->for(User::factory())->renewsOn('2026-10-31')->create();

        $this->assertStringContainsString('انتهى أو متبقي على انتهائه', rawurldecode($student->whatsappUrl()));
    }

    public function test_student_page_links_to_whatsapp_in_new_tab(): void
    {
        $user = User::factory()->create();
        $student = Student::factory()->for($user)->create(['phone' => '01012345678']);

        $this->actingAs($user)->get(route('students.show', $student))
            ->assertSee('https://wa.me/201012345678', false)
            ->assertSee('target="_blank"', false);
    }
}
