import type { CollectionEntry } from 'astro:content';

export const SITE = {
  title: 'Octo E-Shop Copilot Demos',
  shortTitle: 'Octo E-Shop',
  description:
    'A hands-on guide for showcasing GitHub Copilot across a real bicycle e-commerce microservices platform.',
  tagline:
    'Show GitHub Copilot doing real work — planning, coding, reviewing, and securing a production-shaped microservices platform.',
  repo: 'https://github.com/edinc/octo-eshop-demo',
  codespaces: 'https://codespaces.new/edinc/octo-eshop-demo',
  copilot: 'https://github.com/features/copilot',
};

/** Prefix a path with the configured base (e.g. /octo-eshop-demo). */
export function href(path = '/'): string {
  // Pass external links and in-page hash/query navigation through unchanged.
  if (/^(#|\?|https?:\/\/|mailto:|tel:)/i.test(path)) return path;
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  if (!path || path === '/') return `${base}/`;
  return `${base}/${path.replace(/^\//, '')}`;
}

/** Order + default icon for each nav category. */
export const CATEGORY_ORDER = ['Getting Started', 'Demos', 'Guides', 'Reference'] as const;
export type Category = (typeof CATEGORY_ORDER)[number];

export const CATEGORY_ICON: Record<Category, string> = {
  'Getting Started': 'play',
  Demos: 'sparkles',
  Guides: 'book-open',
  Reference: 'layers',
};

/** Primary top-nav entries (first page of each group). */
export const TOP_NAV = [
  { label: 'Get Started', slug: 'getting-started' },
  { label: 'Demos', slug: 'demos/01-plan-agent' },
  { label: 'Guides', slug: 'guides/end-to-end-demo' },
  { label: 'Reference', slug: 'reference/architecture' },
];

export const DIFFICULTY_ORDER = ['Starter', 'Core', 'Intermediate', 'Advanced'] as const;

type Doc = CollectionEntry<'docs'>;

/** Sort docs by their `order`, then title. */
export function byOrder(a: Doc, b: Doc): number {
  const ao = a.data.order ?? 999;
  const bo = b.data.order ?? 999;
  if (ao !== bo) return ao - bo;
  return a.data.title.localeCompare(b.data.title);
}

/** Group published docs into ordered nav sections. */
export function buildNav(docs: Doc[]) {
  const published = docs.filter(d => !d.data.draft);
  return CATEGORY_ORDER.map(category => ({
    category,
    icon: CATEGORY_ICON[category],
    items: published.filter(d => d.data.category === category).sort(byOrder),
  })).filter(group => group.items.length > 0);
}

/** Flatten nav into a linear reading order for prev/next pagination. */
export function readingOrder(docs: Doc[]): Doc[] {
  return buildNav(docs).flatMap(g => g.items);
}
