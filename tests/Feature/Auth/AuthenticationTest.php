<?php

namespace Tests\Feature\Auth;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class AuthenticationTest extends TestCase
{
    use RefreshDatabase;

    public function test_guests_are_redirected_to_login(): void
    {
        $this->get('/students')->assertRedirect(route('login'));
    }

    public function test_login_screen_renders_in_arabic_rtl(): void
    {
        $this->get('/login')
            ->assertOk()
            ->assertSee('dir="rtl"', false)
            ->assertSee(__('auth.login.title'));
    }

    public function test_users_can_register(): void
    {
        $this->post('/register', $this->withSubmissionToken([
            'name' => 'أحمد',
            'email' => 'Ahmed@Example.com',
            'password' => 'password123',
            'password_confirmation' => 'password123',
        ]))->assertRedirect(route('students.index'));

        $this->assertAuthenticated();
        $this->assertDatabaseHas('users', ['email' => 'ahmed@example.com']);
    }

    public function test_users_can_log_in_and_out(): void
    {
        $user = User::factory()->create();

        $this->post('/login', ['email' => $user->email, 'password' => 'password'])
            ->assertRedirect(route('students.index'));
        $this->assertAuthenticatedAs($user);

        $this->post('/logout')->assertRedirect(route('login'));
        $this->assertGuest();
    }

    public function test_wrong_password_shows_arabic_error(): void
    {
        $user = User::factory()->create();

        $this->from('/login')
            ->post('/login', ['email' => $user->email, 'password' => 'wrong'])
            ->assertRedirect('/login')
            ->assertSessionHasErrors(['email' => __('auth.failed')]);

        $this->assertGuest();
    }
}
