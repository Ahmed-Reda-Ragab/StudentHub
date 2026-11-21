<?php

use App\Http\Controllers\SreLabController;
use Illuminate\Support\Facades\Route;

/*
| Loaded from bootstrap/app.php under the "/sre-lab" prefix, outside the "web"
| group (no session, no CSRF) and behind EnsureSreLabEnabled.
| Always registered (so `route:cache` works); disabled = 404 at runtime.
*/

Route::controller(SreLabController::class)->group(function () {
    Route::get('/ping', 'ping')->name('ping');
    Route::get('/version', 'version')->name('version');
    Route::get('/latency', 'latency')->name('latency');
    Route::get('/error', 'fail')->name('error');
    Route::get('/cpu', 'cpu')->name('cpu');
    Route::get('/memory', 'memory')->name('memory');
    Route::get('/db', 'db')->name('db');
    Route::get('/db/heavy', 'dbHeavy')->name('db.heavy');
    Route::post('/unready', 'markUnready')->name('unready');
    Route::post('/ready', 'markReady')->name('ready');
});
