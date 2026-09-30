<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Every subscription/renewal records what the student paid (price) and the
 * user's cut of it (commission = profit). Replaces the unused `amount` placeholder.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('subscriptions', function (Blueprint $table) {
            $table->decimal('price', 10, 2)->nullable()->after('ends_on');
            $table->decimal('commission', 10, 2)->nullable()->after('price');
        });

        // Backfill existing rows with the configured defaults.
        DB::table('subscriptions')->update([
            'price' => DB::raw('coalesce(amount, '.(float) config('subscriptions.pricing.price').')'),
            'commission' => (float) config('subscriptions.pricing.commission'),
        ]);

        Schema::table('subscriptions', function (Blueprint $table) {
            $table->decimal('price', 10, 2)->nullable(false)->change();
            $table->decimal('commission', 10, 2)->nullable(false)->change();
            $table->dropColumn('amount');
        });
    }

    public function down(): void
    {
        Schema::table('subscriptions', function (Blueprint $table) {
            $table->decimal('amount', 10, 2)->nullable()->after('ends_on');
        });

        DB::table('subscriptions')->update(['amount' => DB::raw('price')]);

        Schema::table('subscriptions', function (Blueprint $table) {
            $table->dropColumn(['price', 'commission']);
        });
    }
};
