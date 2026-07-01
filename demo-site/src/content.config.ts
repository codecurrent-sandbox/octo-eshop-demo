import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const docs = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    description: z.string().optional(),
    draft: z.boolean().default(false),
    // Navigation / grouping
    category: z.enum(['Getting Started', 'Demos', 'Guides', 'Reference']).optional(),
    order: z.number().default(999),
    // Demo-specific metadata (drives the home grid + doc headers)
    capability: z.string().optional(),
    duration: z.string().optional(),
    difficulty: z.enum(['Starter', 'Core', 'Intermediate', 'Advanced']).optional(),
    icon: z.string().optional(),
    summary: z.string().optional(),
  }),
});

export const collections = { docs };
