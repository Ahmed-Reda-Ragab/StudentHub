<?php

namespace App\Providers;

use App\Support\SubscriptionPeriod;
use App\Support\WhatsApp\WhatsAppLinkBuilder;
use App\View\Composers\NavigationComposer;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Date;
use Illuminate\Support\Facades\View;
use Illuminate\Support\ServiceProvider;
use Illuminate\Validation\Rules\Password;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        $this->app->singleton(SubscriptionPeriod::class, fn () => SubscriptionPeriod::fromConfig());

        $this->app->singleton(WhatsAppLinkBuilder::class, fn () => new WhatsAppLinkBuilder(
            defaultCountryCode: (string) config('subscriptions.whatsapp.default_country_code'),
            baseUrl: (string) config('subscriptions.whatsapp.base_url'),
        ));

        // One instance per request so the bell count is queried once.
        $this->app->scoped(NavigationComposer::class);
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        Date::use(CarbonImmutable::class);
        Carbon::setLocale($this->app->getLocale());

        Model::shouldBeStrict(! $this->app->isProduction());

        Password::defaults(fn () => Password::min(8));

        View::composer('components.layouts.app', NavigationComposer::class);
    }
}
