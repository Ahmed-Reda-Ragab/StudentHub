<?php

return [

    /*
    | Length of one subscription period in calendar months.
    | next_renewal_date = last_subscription_date + N months (same day of month, clamped to month end);
    | the period ends (last covered day) the day before the next renewal.
    */
    'period_months' => (int) env('SUBSCRIPTION_PERIOD_MONTHS', 1),

    /*
    | Default price and commission (profit) pre-filled for every subscription/renewal.
    | Both remain editable per entry.
    */
    'pricing' => [
        'price' => (float) env('SUBSCRIPTION_DEFAULT_PRICE', 200),
        'commission' => (float) env('SUBSCRIPTION_DEFAULT_COMMISSION', 50),
    ],

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
