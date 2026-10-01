<?php

use App\Http\Controllers\DashboardController;
use App\Http\Controllers\NotificationController;
use App\Http\Controllers\RenewalController;
use App\Http\Controllers\ReportController;
use App\Http\Controllers\StudentController;
use App\Http\Controllers\SubscriptionController;
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

    Route::post('/students/{student}/renewals', [RenewalController::class, 'store'])
        ->name('students.renewals.store');

    Route::resource('subscriptions', SubscriptionController::class)->only(['update', 'destroy']);

    Route::get('/notifications', [NotificationController::class, 'index'])->name('notifications.index');

    Route::get('/reports', [ReportController::class, 'index'])->name('reports.index');
});

require __DIR__.'/auth.php';
