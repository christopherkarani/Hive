// @ts-check
const { themes: prismThemes } = require('prism-react-renderer');

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Hive',
  tagline: 'LangGraph for Swift. Deterministic agent workflows with byte-identical output on every run.',
  favicon: 'img/favicon.ico',

  url: 'https://christopherkarani.github.io',
  baseUrl: '/Hive/',

  organizationName: 'christopherkarani',
  projectName: 'Hive',

  onBrokenLinks: 'throw',
  onBrokenAnchors: 'warn',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: './sidebars.js',
          editUrl: 'https://github.com/christopherkarani/Hive/tree/master/website/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      colorMode: {
        defaultMode: 'dark',
        disableSwitch: false,
        respectPrefersColorScheme: false,
      },
      navbar: {
        title: 'Hive',
        logo: {
          alt: 'Hive Logo',
          src: 'img/hive-logo.svg',
        },
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'docsSidebar',
            position: 'left',
            label: 'Docs',
          },
          {
            href: 'https://christopherkarani.github.io/Hive/api/',
            label: 'API Reference',
            position: 'left',
          },
          {
            href: 'https://github.com/christopherkarani/Hive',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              { label: 'Getting Started', to: '/docs/intro' },
              { label: 'Architecture', to: '/docs/architecture' },
              { label: 'DSL Overview', to: '/docs/dsl/overview' },
            ],
          },
          {
            title: 'API Reference',
            items: [
              { label: 'Hive', href: 'https://christopherkarani.github.io/Hive/api/' },
              { label: 'HiveCore', href: 'https://christopherkarani.github.io/Hive/api/hivecore/' },
              { label: 'HiveDSL', href: 'https://christopherkarani.github.io/Hive/api/hivedsl/' },
            ],
          },
          {
            title: 'More',
            items: [
              { label: 'GitHub', href: 'https://github.com/christopherkarani/Hive' },
              { label: 'MIT License', href: 'https://github.com/christopherkarani/Hive/blob/master/LICENSE' },
            ],
          },
        ],
        copyright: `Copyright ${new Date().getFullYear()} Christopher Karani. Built with Docusaurus.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['swift', 'bash'],
      },
    }),
};

module.exports = config;
