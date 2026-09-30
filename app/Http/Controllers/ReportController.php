<?php

namespace App\Http\Controllers;

use App\Services\RevenueReportService;
use Carbon\CarbonImmutable;
use Illuminate\Http\Request;
use Illuminate\View\View;

class ReportController extends Controller
{
    public function index(Request $request, RevenueReportService $report): View
    {
        $validated = $request->validate([
            'from' => ['nullable', 'date_format:Y-m-d'],
            'to' => ['nullable', 'date_format:Y-m-d', 'after_or_equal:from'],
        ]);

        // Default range: the current month up to today.
        $from = isset($validated['from']) ? CarbonImmutable::parse($validated['from']) : today()->startOfMonth();
        $to = isset($validated['to']) ? CarbonImmutable::parse($validated['to']) : today();

        return view('reports.index', [
            'from' => $from,
            'to' => $to,
            'presets' => $this->presets(),
            'totals' => $report->totals($from, $to),
            'daily' => $report->daily($from, $to),
            'entries' => $report->entries($from, $to),
        ]);
    }

    /**
     * @return array<string, array{from: string, to: string}>
     */
    private function presets(): array
    {
        $today = today();
        $lastMonth = $today->subMonthNoOverflow();

        return [
            'today' => ['from' => $today->toDateString(), 'to' => $today->toDateString()],
            'this_month' => ['from' => $today->startOfMonth()->toDateString(), 'to' => $today->toDateString()],
            'last_month' => ['from' => $lastMonth->startOfMonth()->toDateString(), 'to' => $lastMonth->endOfMonth()->toDateString()],
            'this_year' => ['from' => $today->startOfYear()->toDateString(), 'to' => $today->toDateString()],
        ];
    }
}
