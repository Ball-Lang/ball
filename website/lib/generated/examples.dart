// GENERATED — do not edit. Run: dart run tool/generate_examples.dart
// Source: examples/ directory

/// hello_world.ball.json (simplified: main module only, std stripped)
const helloWorldBallJson = r'''
{
  "name": "hello_world",
  "entryModule": "main",
  "entryFunction": "main",
  "modules": [
    {
      "name": "main",
      "functions": [
        {
          "name": "main",
          "body": {
            "call": {
              "module": "std",
              "function": "print",
              "input": {
                "messageCreation": {
                  "typeName": "PrintInput",
                  "fields": [
                    {
                      "name": "message",
                      "value": {
                        "literal": {
                          "stringValue": "Hello, World!"
                        }
                      }
                    }
                  ]
                }
              }
            }
          },
          "metadata": {
            "kind": "function"
          }
        }
      ],
      "moduleImports": [
        {
          "name": "std"
        }
      ]
    }
  ]
}
''';

/// fibonacci.ball.json (simplified: main module only, std stripped)
const fibonacciBallJson = r'''
{
  "name": "fibonacci",
  "entryModule": "main",
  "entryFunction": "main",
  "modules": [
    {
      "name": "main",
      "functions": [
        {
          "name": "fibonacci",
          "inputType": "int",
          "outputType": "int",
          "body": {
            "block": {
              "statements": [
                {
                  "expression": {
                    "call": {
                      "module": "std",
                      "function": "if",
                      "input": {
                        "messageCreation": {
                          "typeName": "",
                          "fields": [
                            {
                              "name": "condition",
                              "value": {
                                "call": {
                                  "module": "std",
                                  "function": "lte",
                                  "input": {
                                    "messageCreation": {
                                      "typeName": "",
                                      "fields": [
                                        {
                                          "name": "left",
                                          "value": {
                                            "reference": {
                                              "name": "n"
                                            }
                                          }
                                        },
                                        {
                                          "name": "right",
                                          "value": {
                                            "literal": {
                                              "intValue": "1"
                                            }
                                          }
                                        }
                                      ]
                                    }
                                  }
                                }
                              }
                            },
                            {
                              "name": "then",
                              "value": {
                                "call": {
                                  "module": "std",
                                  "function": "return",
                                  "input": {
                                    "messageCreation": {
                                      "typeName": "",
                                      "fields": [
                                        {
                                          "name": "value",
                                          "value": {
                                            "reference": {
                                              "name": "n"
                                            }
                                          }
                                        }
                                      ]
                                    }
                                  }
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  }
                }
              ],
              "result": {
                "call": {
                  "module": "std",
                  "function": "add",
                  "input": {
                    "messageCreation": {
                      "typeName": "",
                      "fields": [
                        {
                          "name": "left",
                          "value": {
                            "call": {
                              "function": "fibonacci",
                              "input": {
                                "call": {
                                  "module": "std",
                                  "function": "subtract",
                                  "input": {
                                    "messageCreation": {
                                      "typeName": "",
                                      "fields": [
                                        {
                                          "name": "left",
                                          "value": {
                                            "reference": {
                                              "name": "n"
                                            }
                                          }
                                        },
                                        {
                                          "name": "right",
                                          "value": {
                                            "literal": {
                                              "intValue": "1"
                                            }
                                          }
                                        }
                                      ]
                                    }
                                  }
                                }
                              }
                            }
                          }
                        },
                        {
                          "name": "right",
                          "value": {
                            "call": {
                              "function": "fibonacci",
                              "input": {
                                "call": {
                                  "module": "std",
                                  "function": "subtract",
                                  "input": {
                                    "messageCreation": {
                                      "typeName": "",
                                      "fields": [
                                        {
                                          "name": "left",
                                          "value": {
                                            "reference": {
                                              "name": "n"
                                            }
                                          }
                                        },
                                        {
                                          "name": "right",
                                          "value": {
                                            "literal": {
                                              "intValue": "2"
                                            }
                                          }
                                        }
                                      ]
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      ]
                    }
                  }
                }
              }
            }
          },
          "metadata": {
            "kind": "function",
            "params": [
              {
                "name": "n",
                "type": "int"
              }
            ]
          }
        },
        {
          "name": "main",
          "body": {
            "block": {
              "statements": [
                {
                  "let": {
                    "name": "result",
                    "value": {
                      "call": {
                        "function": "fibonacci",
                        "input": {
                          "literal": {
                            "intValue": "10"
                          }
                        }
                      }
                    },
                    "metadata": {
                      "keyword": "final"
                    }
                  }
                },
                {
                  "expression": {
                    "call": {
                      "module": "std",
                      "function": "print",
                      "input": {
                        "messageCreation": {
                          "typeName": "PrintInput",
                          "fields": [
                            {
                              "name": "message",
                              "value": {
                                "call": {
                                  "module": "std",
                                  "function": "to_string",
                                  "input": {
                                    "messageCreation": {
                                      "typeName": "",
                                      "fields": [
                                        {
                                          "name": "value",
                                          "value": {
                                            "reference": {
                                              "name": "result"
                                            }
                                          }
                                        }
                                      ]
                                    }
                                  }
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  }
                }
              ]
            }
          },
          "metadata": {
            "kind": "function"
          }
        }
      ],
      "moduleImports": [
        {
          "name": "std"
        }
      ]
    }
  ]
}
''';

/// Dart compiled output from examples/fibonacci/dart/fibonacci_compiled.dart
const fibonacciCompiledDart = r'''
// Generated by ball compiler
// Source: fibonacci v1.0.0
// Target: Dart

int fibonacci(int n) {
  if ((n <= 1)) {
    return n;
  }
  return (fibonacci((n - 1)) + fibonacci((n - 2)));
}

void main() {
  final result = fibonacci(10);
  print(result.toString());
}
''';

/// C++ compiled output (includes stripped) from
/// examples/fibonacci/cpp/fibonacci_compiled.cpp
const fibonacciCompiledCpp = r'''
int64_t fibonacci(auto n) {
    if ((n <= 1LL)) {
        /* return */ n;
    }
    return (fibonacci((n - 1LL)) + fibonacci((n - 2LL)));
}

int main() {
    auto result = fibonacci(10LL);
    std::cout << std::to_string(result) << std::endl;
    return 0;
}
''';

