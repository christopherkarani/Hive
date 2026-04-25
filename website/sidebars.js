/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docsSidebar: [
    'intro',
    'architecture',
    {
      type: 'category',
      label: 'Core',
      collapsed: false,
      items: [
        'core/schema',
        'core/store',
        'core/graph',
        'core/runtime',
      ],
    },
    {
      type: 'category',
      label: 'Features',
      collapsed: false,
      items: [
        'features/checkpointing',
        'features/interrupt-resume',
      ],
    },
    {
      type: 'category',
      label: 'Guides',
      items: [
        'guides/installation',
        'guides/error-handling',
        'guides/testing',
        'guides/examples',
      ],
    },
  ],
};

module.exports = sidebars;
