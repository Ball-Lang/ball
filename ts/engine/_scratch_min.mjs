import { BallEngine } from './src/index.ts';

const program = {
  modules: [
    {
      name: 'std',
      functions: [
        { name: 'assign', isBase: true },
        { name: 'print', isBase: true },
      ],
    },
    {
      name: 'std_collections',
      functions: [{ name: 'list_insert', isBase: true }],
    },
    {
      name: 'main',
      functions: [
        {
          name: 'main',
          body: {
            block: {
              statements: [
                {
                  let: {
                    name: 'letters',
                    value: {
                      literal: {
                        listValue: {
                          elements: [
                            { literal: { stringValue: 'a' } },
                            { literal: { stringValue: 'b' } },
                          ],
                        },
                      },
                    },
                  },
                },
                {
                  expression: {
                    call: {
                      module: 'std',
                      function: 'assign',
                      input: {
                        messageCreation: {
                          fields: [
                            { name: 'target', value: { reference: { name: 'letters' } } },
                            {
                              name: 'value',
                              value: {
                                call: {
                                  module: 'std_collections',
                                  function: 'list_insert',
                                  input: {
                                    messageCreation: {
                                      fields: [
                                        { name: 'list', value: { reference: { name: 'letters' } } },
                                        { name: 'index', value: { literal: { intValue: '1' } } },
                                        { name: 'value', value: { literal: { stringValue: 'X' } } },
                                      ],
                                    },
                                  },
                                },
                              },
                            },
                          ],
                        },
                      },
                    },
                  },
                },
                {
                  expression: {
                    call: {
                      module: 'std',
                      function: 'print',
                      input: {
                        messageCreation: {
                          fields: [{ name: 'message', value: { reference: { name: 'letters' } } }],
                        },
                      },
                    },
                  },
                },
              ],
            },
          },
        },
      ],
    },
  ],
  entryModule: 'main',
  entryFunction: 'main',
};

const engine = new BallEngine(JSON.stringify(program));
await engine.run();
console.log('OUTPUT:', engine.getOutput());
