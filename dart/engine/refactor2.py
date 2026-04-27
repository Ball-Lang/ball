"""
Precise refactoring: change BallValue to Object? in internal engine functions.
Keeps public API (BallModuleHandler, BallCallable, callFunction, run) using BallValue.
"""
import re
import sys

def process(content: str) -> str:
    lines = content.split('\n')
    out = []

    # Lines/patterns to NOT change (public API)
    public_patterns = [
        'Future<BallValue> callFunction',
        'Future<BallValue> run()',
        'FutureOr<BallValue> call(String function',
        'typedef BallCallable',
        'FutureOr<BallValue> Function(BallValue)',  # dispatch table type
        'FutureOr<BallValue> Function(BallValue,',  # composed dispatch type
        'class BallFuture',
        'class BallGenerator',
        'class BallModuleHandler',
        'class StdModuleHandler',
        'void register(',
        'void registerComposer(',
        'void unregister(',
        'void init(',
        'BallValue lookup(',  # _Scope.lookup returns BallValue (wraps internally)
        'sealed class BallValue',
        'class BallInt',
        'class BallDouble',
        'class BallString',
        'class BallBool',
        'class BallList',
        'class BallMap',
        'class BallFunction',
        'class BallNull',
        'BallValue wrap(',
        'Object? unwrap(',
        'extension BallValueX',
    ]

    for i, line in enumerate(lines):
        s = line.lstrip()

        # Skip comments
        if s.startswith('//') or s.startswith('///') or s.startswith('*'):
            out.append(line)
            continue

        # Skip public API lines
        is_public = False
        for pat in public_patterns:
            if pat in line:
                is_public = True
                break
        if is_public:
            out.append(line)
            continue

        # Skip the BallCallable typedef and dispatch table type declarations
        if 'Map<String, FutureOr<BallValue>' in line:
            # Change dispatch table types
            line = line.replace('FutureOr<BallValue> Function(BallValue)', 'FutureOr<Object?> Function(Object?)')
            line = line.replace('FutureOr<BallValue> Function(BallValue,', 'FutureOr<Object?> Function(Object?,')

        # Change internal function parameters: BallValue input -> Object? input
        # But NOT in public classes
        if 'BallValue input' in line and 'BallModuleHandler' not in line and 'BallCallable' not in line:
            # Check it's an internal function
            if '_callFunction' in line or '_callBaseFunction' in line or \
               '_resolveAndCallFunction' in line or '_buildConstructorInstance' in line or \
               '_invokeSuperConstructor' in line or '_dispatchBuiltin' in line or \
               '_tryGetterDispatch' in line or '_trySetterDispatch' in line or \
               'callFunction' not in line:
                line = line.replace('BallValue input', 'Object? input')

        # Change BallValue in variable declarations inside engine methods
        # 'BallValue finalResult;' -> 'Object? finalResult;'
        if re.match(r'\s+BallValue \w+[;=]', line) or re.match(r'\s+BallValue \w+$', line):
            line = line.replace('BallValue ', 'Object? ', 1)

        # 'final BallValue left;' -> 'final Object? left;'
        if 'final BallValue ' in line and 'class' not in line:
            line = line.replace('final BallValue ', 'final Object? ')

        # Change closure parameter types: (BallValue input) async { -> (Object? input) async {
        line = re.sub(r'\(BallValue input\)\s*async\s*\{', '(Object? input) async {', line)
        line = re.sub(r'\(BallValue input\)\s*\{', '(Object? input) {', line)

        # Change BallValue in method parameters for internal helpers
        # e.g. 'BallValue value,' in _trySetterDispatch, _syncFieldToSelf
        if '_syncFieldToSelf' in line and 'BallValue val' in line:
            line = line.replace('BallValue val', 'Object? val')
        if '_trySetterDispatch' in line and 'BallValue value' in line:
            line = line.replace('BallValue value', 'Object? value')

        # Change helper function signatures
        # _applyCompoundOp(String op, BallValue current, BallValue val)
        if '_applyCompoundOp' in line and 'BallValue current' in line:
            line = line.replace('BallValue current', 'Object? current').replace('BallValue val', 'Object? val')
        if '_numOpW' in line and 'BallValue a' in line:
            line = line.replace('BallValue a', 'Object? a').replace('BallValue b', 'Object? b')
        if '_intOpW' in line and 'BallValue a' in line:
            line = line.replace('BallValue a', 'Object? a').replace('BallValue b', 'Object? b')

        # _ballEquals(BallValue a, BallValue b)
        if '_ballEquals' in line and 'BallValue a' in line:
            line = line.replace('BallValue a', 'Object? a').replace('BallValue b', 'Object? b')

        # _matchSwitchPattern(BallValue subject, String pattern)
        if '_matchSwitchPattern' in line and 'BallValue subject' in line:
            line = line.replace('BallValue subject', 'Object? subject')

        # _matchesTypePattern(BallValue value, String pattern)
        if '_matchesTypePattern' in line and 'BallValue value' in line:
            line = line.replace('BallValue value', 'Object? value')

        # _ballToString(BallValue v)
        if '_ballToString' in line and 'BallValue v' in line:
            line = line.replace('BallValue v', 'Object? v')
        if '_ballToStringAsync' in line and 'BallValue v' in line:
            line = line.replace('BallValue v', 'Object? v')

        # _stdAssert(BallValue input) etc
        if re.match(r'\s+\w+ _std\w+\(BallValue', line):
            line = line.replace('(BallValue ', '(Object? ')

        # _toInt(BallValue v), _toDouble, _toNum, _toBool, _toIterable
        for fn in ['_toInt', '_toDouble', '_toNum', '_toBool', '_toIterable']:
            if fn in line and 'BallValue v' in line:
                line = line.replace('BallValue v', 'Object? v')

        # _extractBinaryArgs(BallValue input), _extractUnaryArg, _extractField
        for fn in ['_extractBinaryArgs', '_extractUnaryArg', '_extractField']:
            if fn in line and 'BallValue input' in line:
                line = line.replace('BallValue input', 'Object? input')

        # methods map: Map<String, Function> with (BallValue input) closures
        if "methods[func.name] = (BallValue input)" in line:
            line = line.replace("(BallValue input)", "(Object? input)")

        # _dispatchBuiltinInstanceMethod parameters
        if '_dispatchBuiltinInstanceMethod' in line:
            line = line.replace('BallValue self', 'Object? self')
            line = line.replace('BallValue input', 'Object? input')

        # _dispatchBuiltinClassMethod
        if '_dispatchBuiltinClassMethod' in line and 'BallValue' in line:
            line = line.replace('BallValue', 'Object?')

        # BallValue in _evalCppScopeExit
        if '_evalCppScopeExit' in line and 'BallValue' in line:
            line = line.replace('BallValue', 'Object?')

        # BallValue result; in try blocks
        if line.strip() == 'BallValue result;':
            line = line.replace('BallValue result;', 'Object? result;')

        # BallValue flowResult;
        if 'BallValue flowResult;' in line:
            line = line.replace('BallValue flowResult;', 'Object? flowResult;')

        # BallValue syncResult
        if 'BallValue syncResult' in line:
            line = line.replace('BallValue syncResult', 'Object? syncResult')

        out.append(line)

    return '\n'.join(out)

if __name__ == '__main__':
    path = sys.argv[1]
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    result = process(content)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(result)

    print("Done")
