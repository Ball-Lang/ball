/**
 * Ball Playground — application logic.
 * Handles running programs, loading examples, sharing via URL, and UI interaction.
 */

// ── Example Programs ──────────────────────────────────────────────────────────

const EXAMPLES = {
  hello_world: {
    name: "hello_world",
    version: "1.0.0",
    modules: [
      {
        name: "std",
        types: [{ name: "PrintInput", field: [{ name: "message", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_STRING" }] }],
        functions: [{ name: "print", isBase: true }],
        description: "Standard library base module"
      },
      {
        name: "main",
        functions: [{
          name: "main",
          body: {
            call: {
              module: "std", function: "print",
              input: { messageCreation: { typeName: "PrintInput", fields: [{ name: "message", value: { literal: { stringValue: "Hello, World!" } } }] } }
            }
          },
          metadata: { kind: "function" }
        }],
        moduleImports: [{ name: "std" }]
      }
    ],
    entryModule: "main",
    entryFunction: "main"
  },

  fibonacci: {
    name: "fibonacci",
    version: "1.0.0",
    modules: [
      {
        name: "std",
        types: [
          { name: "PrintInput", field: [{ name: "message", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_STRING" }] },
          { name: "BinaryInput", field: [{ name: "left", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_INT64" }, { name: "right", number: 2, label: "LABEL_OPTIONAL", type: "TYPE_INT64" }] }
        ],
        functions: [
          { name: "if", isBase: true },
          { name: "lte", isBase: true },
          { name: "return", isBase: true },
          { name: "add", isBase: true },
          { name: "subtract", isBase: true },
          { name: "to_string", isBase: true },
          { name: "print", isBase: true }
        ]
      },
      {
        name: "main",
        functions: [
          {
            name: "fibonacci",
            body: {
              block: {
                statements: [{
                  expression: {
                    call: { module: "std", function: "if", input: { messageCreation: { typeName: "", fields: [
                      { name: "condition", value: { call: { module: "std", function: "lte", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "n" } } }, { name: "right", value: { literal: { intValue: "1" } } }] } } } } },
                      { name: "then", value: { call: { module: "std", function: "return", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { reference: { name: "n" } } }] } } } } }
                    ] } } }
                  }
                }],
                result: {
                  call: { module: "std", function: "add", input: { messageCreation: { typeName: "", fields: [
                    { name: "left", value: { call: { function: "fibonacci", input: { call: { module: "std", function: "subtract", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "n" } } }, { name: "right", value: { literal: { intValue: "1" } } }] } } } } } } },
                    { name: "right", value: { call: { function: "fibonacci", input: { call: { module: "std", function: "subtract", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "n" } } }, { name: "right", value: { literal: { intValue: "2" } } }] } } } } } } }
                  ] } } }
                }
              }
            },
            metadata: { kind: "function", params: [{ name: "n", type: "int" }] }
          },
          {
            name: "main",
            body: {
              block: {
                statements: [
                  { let: { name: "result", value: { call: { function: "fibonacci", input: { literal: { intValue: "10" } } } } } },
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "PrintInput", fields: [{ name: "message", value: { call: { module: "std", function: "to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { reference: { name: "result" } } }] } } } } }] } } } } }
                ]
              }
            },
            metadata: { kind: "function" }
          }
        ],
        moduleImports: [{ name: "std" }]
      }
    ],
    entryModule: "main",
    entryFunction: "main"
  },

  fizzbuzz: {
    name: "fizzbuzz",
    version: "1.0.0",
    modules: [
      {
        name: "std",
        types: [],
        functions: [
          { name: "for", isBase: true },
          { name: "if", isBase: true },
          { name: "equals", isBase: true },
          { name: "modulo", isBase: true },
          { name: "and", isBase: true },
          { name: "lte", isBase: true },
          { name: "add", isBase: true },
          { name: "assign", isBase: true },
          { name: "print", isBase: true },
          { name: "to_string", isBase: true },
          { name: "less_than", isBase: true },
          { name: "pre_increment", isBase: true }
        ]
      },
      {
        name: "main",
        functions: [{
          name: "main",
          body: {
            call: {
              module: "std", function: "for",
              input: { messageCreation: { typeName: "", fields: [
                { name: "init", value: { literal: { stringValue: "int i = 1" } } },
                { name: "condition", value: { call: { module: "std", function: "lte", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "i" } } }, { name: "right", value: { literal: { intValue: "20" } } }] } } } } },
                { name: "update", value: { call: { module: "std", function: "assign", input: { messageCreation: { typeName: "", fields: [{ name: "target", value: { reference: { name: "i" } } }, { name: "value", value: { call: { module: "std", function: "add", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "i" } } }, { name: "right", value: { literal: { intValue: "1" } } }] } } } } }, { name: "op", value: { literal: { stringValue: "=" } } }] } } } } },
                { name: "body", value: {
                  call: { module: "std", function: "if", input: { messageCreation: { typeName: "", fields: [
                    { name: "condition", value: { call: { module: "std", function: "equals", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { call: { module: "std", function: "modulo", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "i" } } }, { name: "right", value: { literal: { intValue: "15" } } }] } } } } }, { name: "right", value: { literal: { intValue: "0" } } }] } } } } },
                    { name: "then", value: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { literal: { stringValue: "FizzBuzz" } } }] } } } } },
                    { name: "else", value: {
                      call: { module: "std", function: "if", input: { messageCreation: { typeName: "", fields: [
                        { name: "condition", value: { call: { module: "std", function: "equals", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { call: { module: "std", function: "modulo", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "i" } } }, { name: "right", value: { literal: { intValue: "3" } } }] } } } } }, { name: "right", value: { literal: { intValue: "0" } } }] } } } } },
                        { name: "then", value: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { literal: { stringValue: "Fizz" } } }] } } } } },
                        { name: "else", value: {
                          call: { module: "std", function: "if", input: { messageCreation: { typeName: "", fields: [
                            { name: "condition", value: { call: { module: "std", function: "equals", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { call: { module: "std", function: "modulo", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "i" } } }, { name: "right", value: { literal: { intValue: "5" } } }] } } } } }, { name: "right", value: { literal: { intValue: "0" } } }] } } } } },
                            { name: "then", value: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { literal: { stringValue: "Buzz" } } }] } } } } },
                            { name: "else", value: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { call: { module: "std", function: "to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { reference: { name: "i" } } }] } } } } }] } } } } }
                          ] } } }
                        } }
                      ] } } }
                    } }
                  ] } } }
                } }
              ] } }
            }
          },
          metadata: { kind: "function" }
        }],
        moduleImports: [{ name: "std" }]
      }
    ],
    entryModule: "main",
    entryFunction: "main"
  },

  closures: {
    name: "closures",
    version: "1.0.0",
    modules: [
      {
        name: "std",
        types: [],
        functions: [
          { name: "print", isBase: true },
          { name: "add", isBase: true },
          { name: "to_string", isBase: true },
          { name: "concat", isBase: true }
        ]
      },
      {
        name: "main",
        functions: [
          {
            name: "make_adder",
            body: {
              lambda: {
                body: {
                  call: { module: "std", function: "add", input: { messageCreation: { typeName: "", fields: [
                    { name: "left", value: { reference: { name: "base" } } },
                    { name: "right", value: { reference: { name: "x" } } }
                  ] } } }
                },
                metadata: { params: [{ name: "x" }] }
              }
            },
            metadata: { kind: "function", params: [{ name: "base" }] }
          },
          {
            name: "main",
            body: {
              block: {
                statements: [
                  { let: { name: "add5", value: { call: { function: "make_adder", input: { literal: { intValue: "5" } } } } } },
                  { let: { name: "add10", value: { call: { function: "make_adder", input: { literal: { intValue: "10" } } } } } },
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { call: { module: "std", function: "concat", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { literal: { stringValue: "add5(3) = " } } }, { name: "right", value: { call: { module: "std", function: "to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { call: { function: "add5", input: { literal: { intValue: "3" } } } } }] } } } } }] } } } } }] } } } } },
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { call: { module: "std", function: "concat", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { literal: { stringValue: "add10(7) = " } } }, { name: "right", value: { call: { module: "std", function: "to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { call: { function: "add10", input: { literal: { intValue: "7" } } } } }] } } } } }] } } } } }] } } } } },
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { literal: { stringValue: "Closures capture their enclosing scope!" } } }] } } } } }
                ]
              }
            },
            metadata: { kind: "function" }
          }
        ],
        moduleImports: [{ name: "std" }]
      }
    ],
    entryModule: "main",
    entryFunction: "main"
  },

  math_utils: {
    name: "math_utils",
    version: "1.0.0",
    modules: [
      {
        name: "std",
        types: [],
        functions: [
          { name: "print", isBase: true },
          { name: "to_string", isBase: true },
          { name: "concat", isBase: true },
          { name: "math_sqrt", isBase: true },
          { name: "math_pow", isBase: true },
          { name: "math_abs", isBase: true },
          { name: "math_pi", isBase: true },
          { name: "multiply", isBase: true },
          { name: "add", isBase: true },
          { name: "double_to_string", isBase: true }
        ]
      },
      {
        name: "main",
        functions: [
          {
            name: "circle_area",
            body: {
              call: { module: "std", function: "multiply", input: { messageCreation: { typeName: "", fields: [
                { name: "left", value: { call: { module: "std", function: "math_pi", input: { literal: { intValue: "0" } } } } },
                { name: "right", value: { call: { module: "std", function: "math_pow", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { reference: { name: "radius" } } }, { name: "right", value: { literal: { intValue: "2" } } }] } } } } }
              ] } } }
            },
            metadata: { kind: "function", params: [{ name: "radius" }] }
          },
          {
            name: "main",
            body: {
              block: {
                statements: [
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { call: { module: "std", function: "concat", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { literal: { stringValue: "sqrt(144) = " } } }, { name: "right", value: { call: { module: "std", function: "double_to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { call: { module: "std", function: "math_sqrt", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { literal: { intValue: "144" } } }] } } } } }] } } } } }] } } } } }] } } } } },
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { call: { module: "std", function: "concat", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { literal: { stringValue: "2^10 = " } } }, { name: "right", value: { call: { module: "std", function: "to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { call: { module: "std", function: "math_pow", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { literal: { intValue: "2" } } }, { name: "right", value: { literal: { intValue: "10" } } }] } } } } }] } } } } }] } } } } }] } } } } },
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { call: { module: "std", function: "concat", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { literal: { stringValue: "abs(-42) = " } } }, { name: "right", value: { call: { module: "std", function: "to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { call: { module: "std", function: "math_abs", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { literal: { intValue: "-42" } } }] } } } } }] } } } } }] } } } } }] } } } } },
                  { expression: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { call: { module: "std", function: "concat", input: { messageCreation: { typeName: "", fields: [{ name: "left", value: { literal: { stringValue: "circle_area(5) = " } } }, { name: "right", value: { call: { module: "std", function: "double_to_string", input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { call: { function: "circle_area", input: { literal: { intValue: "5" } } } } }] } } } } }] } } } } }] } } } } }
                ]
              }
            },
            metadata: { kind: "function" }
          }
        ],
        moduleImports: [{ name: "std" }]
      }
    ],
    entryModule: "main",
    entryFunction: "main"
  }
};

// ── DOM refs ──────────────────────────────────────────────────────────────────

const editor = document.getElementById('editor');
const output = document.getElementById('output');
const runBtn = document.getElementById('runBtn');
const formatBtn = document.getElementById('formatBtn');
const shareBtn = document.getElementById('shareBtn');
const examplesSelect = document.getElementById('examples');
const statusDot = document.getElementById('statusDot');
const statusText = document.getElementById('statusText');
const programName = document.getElementById('programName');
const programVersion = document.getElementById('programVersion');
const moduleCount = document.getElementById('moduleCount');
const functionCount = document.getElementById('functionCount');
const shareToast = document.getElementById('shareToast');
const divider = document.getElementById('divider');
const editorPane = document.getElementById('editorPane');
const outputPane = document.getElementById('outputPane');

// ── Core logic ────────────────────────────────────────────────────────────────

function clearOutput() {
  output.innerHTML = '';
}

function appendOutput(text, className = '') {
  const line = document.createElement('div');
  line.className = `output-line ${className}`.trim();
  line.textContent = text;
  output.appendChild(line);
  output.scrollTop = output.scrollHeight;
}

function updateStatus(state, text) {
  statusDot.className = `status-dot ${state === 'error' ? 'error' : ''}`;
  statusText.textContent = text;
}

function updateProgramInfo(program) {
  programName.textContent = program.name || '—';
  programVersion.textContent = program.version ? `v${program.version}` : '';
  const mods = program.modules?.length ?? 0;
  moduleCount.textContent = `${mods} module${mods !== 1 ? 's' : ''}`;
  let fns = 0;
  for (const mod of program.modules ?? []) fns += mod.functions?.length ?? 0;
  functionCount.textContent = `${fns} function${fns !== 1 ? 's' : ''}`;
}

function runProgram() {
  clearOutput();
  const source = editor.value.trim();
  if (!source) {
    appendOutput('No program to run.', 'output-info');
    updateStatus('idle', 'Ready');
    return;
  }

  let program;
  try {
    program = JSON.parse(source);
  } catch (e) {
    appendOutput(`JSON Parse Error: ${e.message}`, 'output-error');
    updateStatus('error', 'Parse error');
    return;
  }

  updateProgramInfo(program);

  const startTime = performance.now();
  try {
    const engine = new BallEngine(program, {
      stdout: (msg) => appendOutput(msg),
      stderr: (msg) => appendOutput(msg, 'output-error')
    });
    engine.run();
    const elapsed = (performance.now() - startTime).toFixed(1);
    appendOutput(`\n--- Completed in ${elapsed}ms ---`, 'output-success');
    updateStatus('ok', `Done (${elapsed}ms)`);
  } catch (e) {
    const elapsed = (performance.now() - startTime).toFixed(1);
    appendOutput(`Runtime Error: ${e.message}`, 'output-error');
    if (e.stack) {
      const stackLines = e.stack.split('\n').slice(1, 6).join('\n');
      appendOutput(stackLines, 'output-error');
    }
    updateStatus('error', `Error (${elapsed}ms)`);
  }
}

function formatJSON() {
  const source = editor.value.trim();
  if (!source) return;
  try {
    const parsed = JSON.parse(source);
    editor.value = JSON.stringify(parsed, null, 2);
  } catch (e) {
    appendOutput(`Format Error: ${e.message}`, 'output-error');
  }
}

function shareProgram() {
  const source = editor.value.trim();
  if (!source) return;
  try {
    const encoded = btoa(unescape(encodeURIComponent(source)));
    const url = `${location.origin}${location.pathname}#${encoded}`;
    history.replaceState(null, '', `#${encoded}`);
    navigator.clipboard.writeText(url).then(() => {
      showToast('Link copied to clipboard');
    }).catch(() => {
      showToast('URL updated (copy from address bar)');
    });
  } catch (e) {
    showToast('Failed to encode program');
  }
}

function showToast(msg) {
  shareToast.textContent = msg;
  shareToast.classList.add('visible');
  setTimeout(() => shareToast.classList.remove('visible'), 2500);
}

function loadFromHash() {
  const hash = location.hash.slice(1);
  if (!hash) return false;
  try {
    const decoded = decodeURIComponent(escape(atob(hash)));
    editor.value = decoded;
    return true;
  } catch {
    return false;
  }
}

function loadExample(name) {
  const example = EXAMPLES[name];
  if (!example) return;
  editor.value = JSON.stringify(example, null, 2);
  clearOutput();
  updateProgramInfo(example);
  updateStatus('idle', 'Ready');
  // Clear hash when loading an example
  history.replaceState(null, '', location.pathname);
}

// ── Event listeners ───────────────────────────────────────────────────────────

runBtn.addEventListener('click', runProgram);
formatBtn.addEventListener('click', formatJSON);
shareBtn.addEventListener('click', shareProgram);

examplesSelect.addEventListener('change', (e) => {
  if (e.target.value) {
    loadExample(e.target.value);
    e.target.value = '';
  }
});

document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
    e.preventDefault();
    runProgram();
  }
  if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === 'F') {
    e.preventDefault();
    formatJSON();
  }
});

// Tab key in editor inserts spaces
editor.addEventListener('keydown', (e) => {
  if (e.key === 'Tab') {
    e.preventDefault();
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    editor.value = editor.value.substring(0, start) + '  ' + editor.value.substring(end);
    editor.selectionStart = editor.selectionEnd = start + 2;
  }
});

// ── Resizable panes ───────────────────────────────────────────────────────────

let isDragging = false;

divider.addEventListener('mousedown', (e) => {
  isDragging = true;
  divider.classList.add('dragging');
  e.preventDefault();
});

document.addEventListener('mousemove', (e) => {
  if (!isDragging) return;
  const container = document.querySelector('.main');
  const rect = container.getBoundingClientRect();
  const isVertical = window.innerWidth <= 768;

  if (isVertical) {
    const pct = ((e.clientY - rect.top) / rect.height) * 100;
    editorPane.style.flex = `0 0 ${Math.max(20, Math.min(80, pct))}%`;
    outputPane.style.flex = '1';
  } else {
    const pct = ((e.clientX - rect.left) / rect.width) * 100;
    editorPane.style.flex = `0 0 ${Math.max(20, Math.min(80, pct))}%`;
    outputPane.style.flex = '1';
  }
});

document.addEventListener('mouseup', () => {
  if (isDragging) {
    isDragging = false;
    divider.classList.remove('dragging');
  }
});

// ── Initialization ────────────────────────────────────────────────────────────

(function init() {
  if (!loadFromHash()) {
    // Load hello world by default
    loadExample('hello_world');
  } else {
    // Try to parse and update info
    try {
      const program = JSON.parse(editor.value);
      updateProgramInfo(program);
    } catch {}
  }
  updateStatus('idle', 'Ready');
})();
