<?php

namespace App\Http\Controllers;

use App\Models\Student;
use Illuminate\View\View;

class DashboardController extends Controller
{
    public function __invoke(): View
    {
        return view('dashboard', [
            'counts' => Student::statusCounts(Student::query()),
        ]);
    }
}
