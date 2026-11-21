#!/usr/bin/env node
// Builds docs/devops/SUMMARY.md from the per-group scenario cards in docs/devops/summary/.
//
//   summary/_intro.md      → top of the document
//   summary/<group>.md     → cards "### NN — title" (any order, any file)
//   summary/_appendix.md   → bottom (matrices, cost, cheat sheets) — optional
//
// Cards are sorted by scenario id (01 … 99, 6A after 69) and grouped by catalog part.
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const docs = resolve(here, '..');
const dir = join(docs, 'summary');

const parts = [
    { from: 1, to: 9, title: 'A. الأساسيات' },
    { from: 10, to: 19, title: 'B. الـ Containers' },
    { from: 20, to: 29, title: 'C. EC2 — سيرفر واحد' },
    { from: 30, to: 39, title: 'D. CI/CD' },
    { from: 40, to: 49, title: 'E. EC2 على نطاق أكبر' },
    { from: 50, to: 59, title: 'F. ECS' },
    { from: 60, to: 69, title: 'G. Kubernetes / EKS' },
    { from: 70, to: 79, title: 'H. Observability و SRE' },
    { from: 80, to: 89, title: 'I. الأمان (DevSecOps)' },
    { from: 90, to: 94, title: 'J. الـ IaC بالتفصيل' },
    { from: 95, to: 99, title: 'K. الختام' },
];

// "6A" → 69.5 so it sorts right after 69 and stays in part G.
const numeric = (id) => (/^\d+$/.test(id) ? Number(id) : Number(id[0]) * 10 + 9.5);

const cards = new Map();
for (const file of readdirSync(dir).filter((f) => f.endsWith('.md') && !f.startsWith('_')).sort()) {
    const text = readFileSync(join(dir, file), 'utf8').replace(/\r\n/g, '\n');
    const chunks = text.split(/^(?=### [0-9][0-9A-Z] — )/m).filter((c) => /^### [0-9][0-9A-Z] — /.test(c));
    for (const chunk of chunks) {
        const id = chunk.match(/^### ([0-9][0-9A-Z]) — /)[1];
        if (cards.has(id)) console.warn(`duplicate card ${id} (${file}) — keeping the first one`);
        // Cards become level-2 headings so they show up in the PDF table of contents.
        else cards.set(id, chunk.trim().replace(/^### /, '## '));
    }
}

const ids = [...cards.keys()].sort((a, b) => numeric(a) - numeric(b));
let out = readFileSync(join(dir, '_intro.md'), 'utf8').trim() + '\n';

for (const part of parts) {
    const inPart = ids.filter((id) => numeric(id) >= part.from && numeric(id) < part.to + 1);
    if (inPart.length === 0) continue;
    out += `\n# ${part.title}\n\n`;
    out += inPart.map((id) => cards.get(id)).join('\n\n---\n\n') + '\n';
}

const appendix = join(dir, '_appendix.md');
if (existsSync(appendix)) out += '\n' + readFileSync(appendix, 'utf8').trim() + '\n';

writeFileSync(join(docs, 'SUMMARY.md'), out, 'utf8');
console.log(`SUMMARY.md: ${ids.length} cards (${ids.join(' ')})`);
