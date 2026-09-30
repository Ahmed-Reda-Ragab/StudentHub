<?php

return [
    'accepted' => 'لازم توافق على :attribute.',
    'after' => ':attribute لازم يكون بعد :date.',
    'after_or_equal' => ':attribute لازم يكون :date أو بعده.',
    'before' => ':attribute لازم يكون قبل :date.',
    'before_or_equal' => ':attribute لازم يكون :date أو قبله.',
    'boolean' => 'قيمة :attribute غير صحيحة.',
    'confirmed' => 'تأكيد :attribute غير مطابق.',
    'date' => ':attribute مش تاريخ صحيح.',
    'date_format' => ':attribute لازم يكون تاريخ صحيح.',
    'decimal' => ':attribute لازم يكون رقم بـ :decimal أرقام عشرية.',
    'email' => ':attribute لازم يكون بريد إلكتروني صحيح.',
    'exists' => ':attribute غير موجود.',
    'in' => 'قيمة :attribute غير مسموحة.',
    'integer' => ':attribute لازم يكون رقم صحيح.',
    'max' => [
        'numeric' => ':attribute لازم ميزيدش عن :max.',
        'string' => ':attribute لازم ميزيدش عن :max حرف.',
    ],
    'min' => [
        'numeric' => ':attribute لازم يكون :min على الأقل.',
        'string' => ':attribute لازم يكون :min حروف على الأقل.',
    ],
    'numeric' => ':attribute لازم يكون رقم.',
    'password' => [
        'letters' => ':attribute لازم يحتوي على حرف واحد على الأقل.',
        'mixed' => ':attribute لازم يحتوي على حروف كبيرة وصغيرة.',
        'numbers' => ':attribute لازم يحتوي على رقم واحد على الأقل.',
        'symbols' => ':attribute لازم يحتوي على رمز واحد على الأقل.',
        'uncompromised' => ':attribute ده ظهر في تسريب بيانات، اختار واحد تاني.',
    ],
    'regex' => 'صيغة :attribute غير صحيحة.',
    'required' => ':attribute مطلوب.',
    'string' => ':attribute لازم يكون نص.',
    'unique' => ':attribute ده مستخدم بالفعل.',
    'uuid' => ':attribute غير صحيح.',

    'lte' => [
        'numeric' => ':attribute لازم يكون أقل من أو يساوي :value.',
    ],

    'custom' => [
        'commission' => [
            'lte' => 'العمولة (الربح) لازم متزيدش عن السعر.',
        ],
        'code' => [
            'unique' => 'الكود ده مستخدم لطالب تاني عندك.',
        ],
        'phone' => [
            'regex' => 'رقم الهاتف غير صحيح — أرقام فقط (مثال: 01012345678).',
        ],
    ],

    'attributes' => [
        'name' => 'الاسم',
        'email' => 'البريد الإلكتروني',
        'password' => 'كلمة المرور',
        'phone' => 'رقم الهاتف',
        'code' => 'الكود',
        'section' => 'الشعبة',
        'notes' => 'النبذة',
        'subscribed_on' => 'تاريخ الاشتراك',
        'renewed_on' => 'تاريخ التجديد',
        'note' => 'الملاحظة',
        'price' => 'السعر',
        'commission' => 'العمولة',
    ],
];
