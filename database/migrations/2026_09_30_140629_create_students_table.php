<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('students', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->unsignedInteger('number');
            $table->string('name');
            $table->string('phone', 20);
            $table->string('code', 50);
            $table->string('section', 100);
            $table->text('notes')->nullable();

            // Denormalized from `subscriptions` — written only by SubscriptionService.
            $table->date('first_subscription_date');
            $table->date('last_subscription_date');
            $table->date('next_renewal_date');

            $table->softDeletes();
            $table->timestamps();

            // Numbers and codes stay reserved even after a soft delete (plain unique on purpose).
            $table->unique(['user_id', 'number']);
            $table->unique(['user_id', 'code']);
            $table->index(['user_id', 'next_renewal_date']);
            $table->index(['user_id', 'name']);
            $table->index(['user_id', 'phone']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('students');
    }
};
