import Alpine from 'alpinejs';
import focus from '@alpinejs/focus';

const PERIOD_DAYS = Number(document.documentElement.dataset.periodDays || 30);

const pad = (n) => String(n).padStart(2, '0');

/**
 * 'YYYY-MM-DD' + n days → 'dd/mm/YYYY' (UTC math, so no DST/timezone drift).
 */
function addDaysFormatted(iso, days) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(iso ?? '')) {
        return '';
    }

    const [y, m, d] = iso.split('-').map(Number);
    const date = new Date(Date.UTC(y, m - 1, d + days));

    return `${pad(date.getUTCDate())}/${pad(date.getUTCMonth() + 1)}/${date.getUTCFullYear()}`;
}

Alpine.plugin(focus);

// Live preview of the next renewal date: x-text="$nextRenewal(date)"
Alpine.magic('nextRenewal', () => (iso) => addDaysFormatted(iso, PERIOD_DAYS));

/**
 * Loader + double-submit guard for every form (see <x-form>).
 * Bound to `submit` (not click) so a failed browser validation never leaves the button stuck.
 */
Alpine.data('submitGuard', () => ({
    loading: false,

    init() {
        // Reset when the page is restored from the back/forward cache.
        window.addEventListener('pageshow', () => (this.loading = false));
    },

    guard(event) {
        if (this.loading) {
            event.preventDefault();
            return;
        }

        this.loading = true;
    },
}));

/**
 * Debounced live search: fetches the same page and swaps the results region,
 * keeping q/status in the URL.
 */
Alpine.data('liveSearch', (q = '') => ({
    q,
    loading: false,
    controller: null,

    async run(form) {
        const url = new URL(form.action);

        for (const [key, value] of new FormData(form)) {
            if (String(value).trim() !== '') {
                url.searchParams.set(key, value);
            }
        }

        history.replaceState(null, '', url);

        this.controller?.abort();
        this.controller = new AbortController();
        this.loading = true;

        try {
            const response = await fetch(url, {
                headers: { Accept: 'text/html', 'X-Requested-With': 'XMLHttpRequest' },
                signal: this.controller.signal,
            });

            const html = await response.text();
            const incoming = new DOMParser().parseFromString(html, 'text/html').getElementById('students-results');

            if (incoming) {
                document.getElementById('students-results')?.replaceWith(incoming);
            }
        } catch (error) {
            if (error.name !== 'AbortError') {
                form.submit();
            }
        } finally {
            this.loading = false;
        }
    },

    clear(form) {
        this.q = '';
        this.$nextTick(() => {
            this.run(form);
            form.querySelector('input[name="q"]').focus();
        });
    },
}));

window.Alpine = Alpine;
Alpine.start();

// Move focus to the first invalid field after a failed submission.
document.addEventListener('DOMContentLoaded', () => {
    document.querySelector('main [aria-invalid="true"]')?.focus();
});
