<?php

return [
    'status' => [
        'active' => 'اشتراك فعال',
        'due_tomorrow' => 'التجديد غدًا',
        'due_today' => 'التجديد اليوم',
        'expired' => 'الاشتراك منتهي',
    ],

    'tabs' => [
        'active' => 'فعال',
        'due_tomorrow' => 'غدًا',
        'due_today' => 'اليوم',
        'expired' => 'منتهي',
    ],

    'types' => [
        'initial' => 'اشتراك',
        'renewal' => 'تجديد',
    ],

    'pricing' => [
        'price' => 'السعر',
        'commission' => 'العمولة (الربح)',
        'commission_short' => 'العمولة',
        'currency' => 'ج.م',
        'total_paid' => 'إجمالي المدفوع',
        'total_commission' => 'إجمالي الربح',
    ],

    'history' => [
        'title' => 'سجل الاشتراكات والتجديدات',
        'type' => 'النوع',
        'start_date' => 'التاريخ',
        'ends_on' => 'نهاية الفترة',
        'read_only' => 'للقراءة فقط — لا يمكن تعديل أو حذف السجل.',
    ],

    'renew' => [
        'button' => 'تسجيل تجديد',
        'quick' => 'تجديد',
        'title' => 'تسجيل تجديد',
        'for' => 'الطالب: :name',
        'date' => 'تاريخ التجديد',
        'last' => 'آخر اشتراك/تجديد: :date',
        'submit' => 'تسجيل التجديد',
        'loading' => 'جاري التسجيل...',
    ],

    'messages' => [
        'renewed' => 'تم تسجيل التجديد لـ :name ✅ — التجديد القادم :date',
        'duplicate_renewal' => 'التجديد ده متسجّل بالفعل.',
        'renewal_before_last' => 'تاريخ التجديد لازم يكون بعد آخر تاريخ مسجّل (:date).',
    ],
];
