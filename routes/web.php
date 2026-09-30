<?php

use App\Http\Controllers\DashboardController;
use App\Http\Controllers\NotificationController;
use App\Http\Controllers\RenewalController;
use App\Http\Controllers\StudentController;
use Illuminate\Support\Facades\Route;

Route::redirect('/', '/students');

Route::middleware('auth')->group(function () {
    Route::get('/dashboard', DashboardController::class)
        ->middleware('sync.notifications')
        ->name('dashboard');

    Route::get('/students', [StudentController::class, 'index'])
        ->middleware('sync.notifications')
        ->name('students.index');

    Route::resource('students', StudentController::class)->except('index');

    // Append-only ledger: create only — no update/destroy routes by design.
    Route::post('/students/{student}/renewals', [RenewalController::class, 'store'])
        ->name('students.renewals.store');

    Route::get('/notifications', [NotificationController::class, 'index'])->name('notifications.index');
});

require __DIR__.'/auth.php';
