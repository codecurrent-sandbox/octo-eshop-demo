import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import expressiveCode from 'astro-expressive-code';

// Fully custom site — no Starlight. Astro + MDX for content, Expressive Code
// for GitHub-themed syntax highlighting with a built-in copy button.
export default defineConfig({
  site: 'https://codecurrent-sandbox.github.io',
  base: '/octo-eshop-demo',
  trailingSlash: 'ignore',
  integrations: [
    // Expressive Code must be registered before MDX so it can hook the pipeline.
    expressiveCode({
      themes: ['github-dark-default', 'github-light-default'],
      // Map EC themes to our own [data-theme] toggle instead of a media query.
      themeCssSelector: theme => `[data-theme='${theme.type}']`,
      useDarkModeMediaQuery: false,
      defaultProps: {
        wrap: true,
        overridesByLang: {
          'text,txt': { showLineNumbers: false },
        },
      },
      styleOverrides: {
        borderRadius: '0.75rem',
        codeFontFamily:
          "'JetBrains Mono Variable', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
        codeFontSize: '0.86rem',
        codeLineHeight: '1.65',
        uiFontFamily: "'Mona Sans Variable', ui-sans-serif, system-ui, sans-serif",
        frames: {
          shadowColor: 'transparent',
          editorTabBarBorderBottomColor: 'transparent',
        },
      },
    }),
    mdx(),
  ],
});
