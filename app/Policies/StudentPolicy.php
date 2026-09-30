<?php

namespace App\Policies;

use App\Models\Student;
use App\Models\User;

/**
 * Defense in depth: the BelongsToUser global scope already 404s foreign records;
 * this policy guarantees ownership even if a query bypasses the scope.
 */
class StudentPolicy
{
    public function view(User $user, Student $student): bool
    {
        return $this->owns($user, $student);
    }

    public function update(User $user, Student $student): bool
    {
        return $this->owns($user, $student);
    }

    public function delete(User $user, Student $student): bool
    {
        return $this->owns($user, $student);
    }

    public function renew(User $user, Student $student): bool
    {
        return $this->owns($user, $student);
    }

    private function owns(User $user, Student $student): bool
    {
        return $student->user_id === $user->id;
    }
}
