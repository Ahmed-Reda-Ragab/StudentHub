<?php

namespace App\Enums;

enum SubscriptionType: string
{
    case Initial = 'initial';
    case Renewal = 'renewal';

    public function label(): string
    {
        return __("subscriptions.types.{$this->value}");
    }
}
