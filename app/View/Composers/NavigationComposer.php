<?php

namespace App\View\Composers;

use App\Models\Student;
use Illuminate\Support\Facades\Auth;
use Illuminate\View\View;

/**
 * Bell counter = expired + due today + due tomorrow, computed live from the DB.
 */
class NavigationComposer
{
    private ?int $attentionCount = null;

    public function compose(View $view): void
    {
        if (! Auth::check()) {
            return;
        }

        $this->attentionCount ??= Student::query()->needsAttention()->count();

        $view->with('attentionCount', $this->attentionCount);
    }
}
