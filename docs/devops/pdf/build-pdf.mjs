#!/usr/bin/env node
// Markdown → HTML (RTL Arabic + LTR code) → PDF via Edge/Chrome headless.
//
//   cd docs/devops/pdf && npm ci
//   node build-pdf.mjs --summary     # SUMMARY.md            → ../SUMMARY.pdf
//   node build-pdf.mjs --full        # README + CONVENTIONS + scenarios/*.md → ../HANDBOOK.pdf
//
// Browser: CHROME_PATH env, else Edge/Chrome default locations (Windows, macOS, Linux).
import { marked } from 'marked';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const docsDir = resolve(here, '..');
const mode = process.argv.includes('--full') ? 'full' : 'summary';

// ---------------------------------------------------------------- sources
function scenarioFiles() {
    const dir = join(docsDir, 'scenarios');
    return existsSync(dir)
        ? readdirSync(dir).filter((f) => /^\d+[A-Z]?-.*\.md$/i.test(f)).sort().map((f) => join(dir, f))
        : [];
}

const sources = mode === 'full'
    ? [join(docsDir, 'README.md'), join(docsDir, 'CONVENTIONS.md'), ...scenarioFiles()]
    : [join(docsDir, 'SUMMARY.md')];

const output = join(docsDir, mode === 'full' ? 'HANDBOOK.pdf' : 'SUMMARY.pdf');
const title = mode === 'full'
    ? 'StudentHub DevOps/SRE Lab — Handbook'
    : 'StudentHub DevOps/SRE Lab — الملخص الشامل';

// ---------------------------------------------------------------- markdown → html
const slugCounts = new Map();
const toc = [];

function slugify(text) {
    const base = text
        .toLowerCase()
        .replace(/<[^>]+>/g, '')
        .replace(/[^\p{L}\p{N}\s-]/gu, '')
        .trim()
        .replace(/\s+/g, '-') || 'section';
    const n = slugCounts.get(base) ?? 0;
    slugCounts.set(base, n + 1);
    return n === 0 ? base : `${base}-${n}`;
}

// Anchor id for a whole file so cross-links like scenarios/23-x.md work inside the PDF.
const fileAnchor = (file) => 'file-' + file.replace(/\\/g, '/').split('/').pop().replace(/\.md$/, '');

const renderer = {
    heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens);
        const id = slugify(text);
        if (depth <= 2) toc.push({ depth, id, text: text.replace(/<[^>]+>/g, '') });
        return `<h${depth} id="${id}">${text}</h${depth}>\n`;
    },
    code({ text, lang }) {
        const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        const label = lang ? `<span class="lang">${lang}</span>` : '';
        return `<div class="code" dir="ltr">${label}<pre><code>${escaped}</code></pre></div>\n`;
    },
    link({ href, title: linkTitle, tokens }) {
        const text = this.parser.parseInline(tokens);
        let target = href ?? '';
        // Internal doc links become in-PDF anchors in the full handbook.
        const md = target.match(/(?:^|\/)([^/]+)\.md(#.*)?$/);
        if (mode === 'full' && md && !/^https?:/.test(target)) {
            target = md[2] ? md[2] : `#${fileAnchor(md[1] + '.md')}`;
        }
        const t = linkTitle ? ` title="${linkTitle}"` : '';
        return `<a href="${target}"${t}>${text}</a>`;
    },
};

marked.use({ renderer, gfm: true });

// Any Arabic letter in a block → RTL; pure English/code → LTR. (dir="auto" picks LTR for
// Arabic sentences that *start* with an English term, which scrambles the line.)
function dirOf(fragment) {
    const text = fragment.replace(/<code>[\s\S]*?<\/code>/g, '').replace(/<[^>]+>/g, '');
    return /[؀-ۿ]/.test(text) ? 'rtl' : 'ltr';
}

function addDirAuto(html) {
    return html
        .replace(/<(p|td|th|h[1-6])((?:\s[^>]*)?)>([\s\S]*?)<\/\1>/g, (m, tag, attrs, inner) => {
            const cleaned = attrs.replace(/\sdir="[^"]*"/, '');
            return `<${tag}${cleaned} dir="${dirOf(inner)}">${inner}</${tag}>`;
        })
        .replace(/<li>([\s\S]*?)(?=<\/li>|<ul|<ol)/g, (m, inner) => `<li dir="${dirOf(inner)}">${inner}`)
        .replace(/<blockquote>/g, '<blockquote dir="rtl">')
        // <details> (interview answers) must be open, otherwise print hides the content.
        .replace(/<details>/g, '<details open>');
}

let body = '';
for (const file of sources) {
    if (!existsSync(file)) {
        console.error(`missing: ${file}`);
        process.exit(1);
    }
    const md = readFileSync(file, 'utf8');
    body += `<section class="doc" id="${fileAnchor(file)}">\n${addDirAuto(marked.parse(md))}\n</section>\n`;
}

const tocHtml = toc
    .filter((h) => (mode === 'full' ? h.depth === 1 : h.depth <= 2))
    .map((h) => `<li class="toc-${h.depth}" dir="${dirOf(h.text)}"><a href="#${h.id}">${h.text}</a></li>`)
    .join('\n');

const css = readFileSync(join(here, 'style.css'), 'utf8');
const today = new Date().toISOString().slice(0, 10);

const html = `<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<title>${title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<style>${css}</style>
</head>
<body>
<section class="cover">
  <div class="cover-kicker" dir="ltr">Laravel · Docker · AWS · Terraform · Ansible · Kubernetes · SRE</div>
  <h1 class="cover-title" dir="auto">${title}</h1>
  <p class="cover-sub" dir="auto">EC2 + Docker Compose → CI/CD (GitHub Actions &amp; AWS CodeBuild) → Zero-downtime strategies → ECS → EKS — Console + IaC</p>
  <p class="cover-meta" dir="ltr">github.com/Ahmed-Reda-Ragab/StudentHub · ${today}</p>
</section>
<nav class="toc">
  <h2 dir="auto">المحتويات</h2>
  <ol>${tocHtml}</ol>
</nav>
${body}
</body>
</html>`;

const buildDir = join(here, 'build');
mkdirSync(buildDir, { recursive: true });
const htmlFile = join(buildDir, `${mode}.html`);
writeFileSync(htmlFile, html, 'utf8');
console.log(`html: ${htmlFile}`);

// ---------------------------------------------------------------- html → pdf
const candidates = [
    process.env.CHROME_PATH,
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/usr/bin/microsoft-edge',
].filter(Boolean);
const browser = candidates.find((p) => existsSync(p));
if (!browser) {
    console.error('No Edge/Chrome found — set CHROME_PATH. The HTML is ready to print manually.');
    process.exit(2);
}

const result = spawnSync(browser, [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-pdf-header-footer',
    '--virtual-time-budget=20000',
    `--print-to-pdf=${output}`,
    pathToFileURL(htmlFile).href,
], { stdio: 'inherit' });

if (result.status !== 0 || !existsSync(output)) {
    console.error(`PDF generation failed (exit ${result.status}).`);
    process.exit(1);
}
console.log(`pdf:  ${output}`);
