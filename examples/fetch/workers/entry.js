// The Workers entry: the shim imports the compiled MoonBit module inside the
// first request, because evaluating it generates random values (its hash
// seed), which Workers refuses in global scope.
import { workers } from '../../../mttp_async/hosts/adapters.mjs';

export default workers(() => import('../../../_build/js/debug/build/gaato/mttp-fetch-example/workers/workers.js'));
