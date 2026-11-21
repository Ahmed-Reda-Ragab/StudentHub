<?php

namespace Tests\Feature;

use App\Models\Student;
use App\Models\User;
use Database\Seeders\LoadTestSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class LoadTestSeederTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_seeds_users_with_students_and_is_idempotent(): void
    {
        config(['sre_lab.loadtest.users' => 2, 'sre_lab.loadtest.students_per_user' => 3]);

        $this->seed(LoadTestSeeder::class);
        $this->seed(LoadTestSeeder::class);

        $this->assertSame(2, User::query()->where('email', 'like', 'loadtest%@example.com')->count());
        $this->assertSame(6, Student::query()->count());

        $this->post('/login', ['email' => 'loadtest1@example.com', 'password' => 'password'])
            ->assertRedirect(route('students.index'));
    }
}
