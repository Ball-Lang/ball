import './engine_rt.ts';
// If we got here, Node parsed & loaded the file (class/typedef
// declarations ran, top-level async function did not invoke since the
// engine is a library).
console.log('engine_rt.ts loaded OK');
