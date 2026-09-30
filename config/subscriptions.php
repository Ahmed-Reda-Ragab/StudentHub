<?php

return [

    /*
    | Length of one subscription period. next_renewal_date = last_subscription_date + period_days.
    */
    'period_days' => (int) env('SUBSCRIPTION_PERIOD_DAYS', 30),

    /*
    | Students per page on the students list.
    */
    'per_page' => 25,

    /*
    | How long (seconds) a form submission token is remembered to swallow double submits.
    */
    'submission_token_ttl' => 60,

    'whatsapp' => [
        // Country code used when a local number (e.g. 01xxxxxxxxx) is entered.
        'default_country_code' => (string) env('WHATSAPP_DEFAULT_COUNTRY_CODE', '20'),
        'base_url' => 'https://wa.me',
    ],

];
