///<reference path="./WebBackend.d.ts">

import frontendWasmUrl from './zig-out/bin/dvui-frontend.wasm?url';
import { downloadFile, uploadFile } from './localFileManip';

// TODO: remove references to dvui in prod build (but acknowledge it somewhere)

/** @param {number} ms */
async function dvui_sleep(ms) {
    await new Promise(r => setTimeout(r, ms));
}

async function dvui_fetch(url) {
    let x = await fetch(url);
    let blob = await x.blob();
    //console.log("dvui_fetch: " + blob.size);
    return new Uint8Array(await blob.arrayBuffer());
}

/**
 * @param {any} cond
 * @param {string} errMessage
 */
function assert(cond, errMessage = "Assertion failed") {
    if (!cond) throw Error(errMessage);
}

const MAX_FUNC_NAME = 256;
const WASM_PAGE_SIZE = 64 * 1024;
const INIT_BUFFER_SZ = WASM_PAGE_SIZE;

// FIXME: this should return a promise
/**
 * @param {HTMLCanvasElement} canvasElem
 * @param {import("./WebBackend").Ide.Options} opts
 */
export function Ide(canvasElem, opts) {
    /** @type {Map<number, { name: string, func: Required<Pick<import("./WebBackend").BasicMutNodeDescJson, "impl" | "inputs" | "outputs">> }>} */
    const userFuncs = new Map();

    /** @type {Map<number, (() => void) | undefined>} */
    const menuOnClick = new Map();

    const vertexShaderSource_webgl = `
        precision mediump float;

        attribute vec4 aVertexPosition;
        attribute vec4 aVertexColor;
        attribute vec2 aTextureCoord;

        uniform mat4 uMatrix;

        varying vec4 vColor;
        varying vec2 vTextureCoord;

        void main() {
          gl_Position = uMatrix * aVertexPosition;
          vColor = aVertexColor / 255.0;  // normalize u8 colors to 0-1
          vTextureCoord = aTextureCoord;
        }
    `;

    const vertexShaderSource_webgl2 = `# version 300 es

        precision mediump float;

        in vec4 aVertexPosition;
        in vec4 aVertexColor;
        in vec2 aTextureCoord;

        uniform mat4 uMatrix;

        out vec4 vColor;
        out vec2 vTextureCoord;

        void main() {
          gl_Position = uMatrix * aVertexPosition;
          vColor = aVertexColor / 255.0;  // normalize u8 colors to 0-1
          vTextureCoord = aTextureCoord;
        }
    `;


    const fragmentShaderSource_webgl = `
        precision mediump float;

        varying vec4 vColor;
        varying vec2 vTextureCoord;

        uniform sampler2D uSampler;
        uniform bool useTex;

        void main() {
            if (useTex) {
                gl_FragColor = texture2D(uSampler, vTextureCoord) * vColor;
            }
            else {
                gl_FragColor = vColor;
            }
        }
    `;

    const fragmentShaderSource_webgl2 = `# version 300 es

        precision mediump float;

        in vec4 vColor;
        in vec2 vTextureCoord;

        uniform sampler2D uSampler;
        uniform bool useTex;

        out vec4 fragColor;

        void main() {
            if (useTex) {
                fragColor = texture(uSampler, vTextureCoord) * vColor;
            }
            else {
                fragColor = vColor;
            }
        }
    `;

    let webgl2 = true;
    let gl;
    let indexBuffer;
    let vertexBuffer;
    let shaderProgram;
    let programInfo;
    const textures = new Map();
    let newTextureId = 1;
    let using_fb = false;
    let frame_buffer = null;
    let renderTargetSize = [0, 0];

    const sharedWasmMem = new WebAssembly.Memory({
        initial: 50, // measured in pages of 64KiB
        maximum: 200,
        shared: true,
    });
    let wasmOpt;
    let wasmResult;
    let log_string = '';
    let hidden_input;
    let touches = [];  // list of tuple (touch identifier, initial index)
    let textInputRect = [];  // x y w h of on screen keyboard editing position, or empty if none
    /** @type {undefined | WebAssembly.WebAssemblyInstantiatedSource} */
    let lastCompiled;


    function oskCheck() {
        if (textInputRect.length == 0) {
            gl.canvas.focus();
        } else {
            // TODO: fix so hidden_input is always matching the canvas?
            hidden_input.style.left = (window.scrollX + canvasElem.getBoundingClientRect().left + textInputRect[0]) + 'px';
            hidden_input.style.top = (window.scrollY + canvasElem.getBoundingClientRect().top + textInputRect[1]) + 'px';
            hidden_input.style.width = textInputRect[2] + 'px';
            hidden_input.style.height = textInputRect[3] + 'px';
            hidden_input.focus();
        }
    }

    function touchIndex(pointerId) {
        let idx = touches.findIndex((e) => e[0] === pointerId);
        if (idx < 0) {
            idx = touches.length;
            touches.push([pointerId, idx]);
        }

        return idx;
    }

    const utf8decoder = new TextDecoder();
    const utf8encoder = new TextEncoder();

    // FIXME: gross, instead expose ide.exportCompiled and allow the host
    // to define custom menu items using that to download the file
    /** @type {undefined | (() => void)} */
    let onExportCompiledOverride = undefined;

    /**
     * @param {Uint8Array} data
     * @returns {Uint8Array}
     */
    function compileWat_binaryen(data) {
        const inputFile = '/input.wat';
        const outputFile = '/optimized.wasm';
        wasmOpt.FS.writeFile(inputFile, data);
        // TODO: source maps
        // FIXME: consider whether it's worth enabling optimizations

        const status = wasmOpt.callMain([
            inputFile,
            '-o',
            outputFile,
            //'-g',
            // NOTE: multimemory not supported by safari
            "--enable-bulk-memory",
            //"--enable-multivalue",
        ]);

        if (status !== 0)
            throw Error(`non-zero return: ${status}`)

        return wasmOpt.FS.readFile(outputFile, { encoding: "binary" });
    }

    // FIXME: use this, it's no optimizer but it's much much lighter
    async function compileWat_wabt() {
        const wabt = await wabtPromise;
        var module = wabt.parseWat('graph.wat', data, {});

        module.resolveNames();
        module.validate({});
        const binaryOutput = module.toBinary({log: true, write_debug_names:true});
        const outputLog = binaryOutput.log;
        console.warn(outputLog);
        const binaryBuffer = binaryOutput.buffer;
        return binaryBuffer;
    }


    const imports = {
        env: {

        wasm_opt_transfer: sharedWasmMem,

        wasm_about_webgl2: () => {
            if (webgl2) {
                return 1;
            } else {
                return 0;
            }
        },
        wasm_panic: (ptr, len) => {
            let msg = utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len));
            alert(msg);
            throw Error(msg);
        },
        wasm_log_write: (ptr, len) => {
            log_string += utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len));
        },
        wasm_log_flush: () => {
            console.log(log_string);
            log_string = '';
        },
        wasm_now() {
            return performance.now();
        },
        wasm_sleep(ms) {
            dvui_sleep(ms);
        },
        wasm_pixel_width() {
            return gl.drawingBufferWidth;
        },
        wasm_pixel_height() {
            return gl.drawingBufferHeight;
        },
        wasm_frame_buffer() {
           if (using_fb)
               return 1;
           else
               return 0;
        },
        wasm_canvas_width() {
            return gl.canvas.clientWidth;
        },
        wasm_canvas_height() {
            return gl.canvas.clientHeight;
        },
        wasm_textureCreate(pixels, width, height, interp) {
            const pixelData = new Uint8Array(wasmResult.instance.exports.memory.buffer, pixels, width * height * 4);

            const texture = gl.createTexture();
            const id = newTextureId;
            //console.log("creating texture " + id);
            newTextureId += 1;
            textures.set(id, [texture, width, height]);
          
            gl.bindTexture(gl.TEXTURE_2D, texture);

            gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA,
                width,
                height,
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                pixelData,
            );

            if (webgl2) {
                gl.generateMipmap(gl.TEXTURE_2D);
	    }

	    if (interp == 0) {
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
	    } else {
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
	    }
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

            return id;
        },
        wasm_textureCreateTarget(width, height, interp) {
            const texture = gl.createTexture();
            const id = newTextureId;
            //console.log("creating texture " + id);
            newTextureId += 1;
            textures.set(id, [texture, width, height]);

            gl.bindTexture(gl.TEXTURE_2D, texture);

            gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA,
                width,
                height,
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                null,
            );

           if (interp == 0) {
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
           } else {
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
           }
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

           return id;
       },
       wasm_renderTarget(id) {
           if (id === 0) {
               using_fb = false;
               gl.bindFramebuffer(gl.FRAMEBUFFER, null);
               renderTargetSize = [gl.drawingBufferWidth, gl.drawingBufferHeight];
               gl.viewport(0, 0, renderTargetSize[0], renderTargetSize[1]);
               gl.scissor(0, 0, renderTargetSize[0], renderTargetSize[1]);
           } else {
               using_fb = true;
               gl.bindFramebuffer(gl.FRAMEBUFFER, frame_buffer);

               gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, textures.get(id)[0], 0);
               renderTargetSize = [textures.get(id)[1], textures.get(id)[2]];
               gl.viewport(0, 0, renderTargetSize[0], renderTargetSize[1]);
               gl.scissor(0, 0, renderTargetSize[0], renderTargetSize[1]);
           }
       },
        wasm_textureRead(textureId, pixels_out, width, height) {
            const texture = textures.get(textureId)[0];

            gl.bindFramebuffer(gl.FRAMEBUFFER, frame_buffer);
            gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);

            var dest = new Uint8Array(wasmResult.instance.exports.memory.buffer, pixels_out, width * height * 4);
            gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, dest, 0);
        
            gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        },
        wasm_textureDestroy(id) {
            //console.log("deleting texture " + id);
            const texture = textures.get(id)[0];
            textures.delete(id);

            gl.deleteTexture(texture);
        },
        wasm_renderGeometry(textureId, index_ptr, index_len, vertex_ptr, vertex_len, sizeof_vertex, offset_pos, offset_col, offset_uv, clip, x, y, w, h) {
            //console.log("drawClippedTriangles " + textureId + " sizeof " + sizeof_vertex + " pos " + offset_pos + " col " + offset_col + " uv " + offset_uv);

	    //let old_scissor;
	    if (clip === 1) {
		// just calling getParameter here is quite slow (5-10 ms per frame according to chrome)
                //old_scissor = gl.getParameter(gl.SCISSOR_BOX);
                gl.scissor(x, y, w, h);
            }

            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
            const indices = new Uint16Array(wasmResult.instance.exports.memory.buffer, index_ptr, index_len / 2);
            gl.bufferData( gl.ELEMENT_ARRAY_BUFFER, indices, gl.STATIC_DRAW);

            gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
            const vertexes = new Uint8Array(wasmResult.instance.exports.memory.buffer, vertex_ptr, vertex_len);
            gl.bufferData( gl.ARRAY_BUFFER, vertexes, gl.STATIC_DRAW);

            let matrix = new Float32Array(16);
            matrix[0] = 2.0 / renderTargetSize[0];
            matrix[1] = 0.0;
            matrix[2] = 0.0;
            matrix[3] = 0.0;
            matrix[4] = 0.0;
           if (using_fb) {
               matrix[5] = 2.0 / renderTargetSize[1];
           } else {
               matrix[5] = -2.0 / renderTargetSize[1];
           }
            matrix[6] = 0.0;
            matrix[7] = 0.0;
            matrix[8] = 0.0;
            matrix[9] = 0.0;
            matrix[10] = 1.0;
            matrix[11] = 0.0;
            matrix[12] = -1.0;
           if (using_fb) {
                matrix[13] = -1.0;
           } else {
                matrix[13] = 1.0;
           }
            matrix[14] = 0.0;
            matrix[15] = 1.0;

            // vertex
            gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
            gl.vertexAttribPointer(
                programInfo.attribLocations.vertexPosition,
                2,  // num components
                gl.FLOAT,
                false,  // don't normalize
                sizeof_vertex,  // stride
                offset_pos,  // offset
            );
            gl.enableVertexAttribArray(programInfo.attribLocations.vertexPosition);

            // color
            gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
            gl.vertexAttribPointer(
                programInfo.attribLocations.vertexColor,
                4,  // num components
                gl.UNSIGNED_BYTE,
                false,  // don't normalize
                sizeof_vertex, // stride
                offset_col,  // offset
            );
            gl.enableVertexAttribArray(programInfo.attribLocations.vertexColor);

            // texture
            gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
            gl.vertexAttribPointer(
            programInfo.attribLocations.textureCoord,
                2,  // num components
                gl.FLOAT,
                false,  // don't normalize
                sizeof_vertex, // stride
                offset_uv,  // offset
            );
            gl.enableVertexAttribArray(programInfo.attribLocations.textureCoord);

            // Tell WebGL to use our program when drawing
            gl.useProgram(shaderProgram);

            // Set the shader uniforms
            gl.uniformMatrix4fv(
            programInfo.uniformLocations.matrix,
            false,
            matrix,
            );

            if (textureId != 0) {
                gl.activeTexture(gl.TEXTURE0);
                gl.bindTexture(gl.TEXTURE_2D, textures.get(textureId)[0]);
                gl.uniform1i(programInfo.uniformLocations.useTex, 1);
            } else {
                gl.uniform1i(programInfo.uniformLocations.useTex, 0);
            }

            gl.uniform1i(programInfo.uniformLocations.uSampler, 0);

            gl.drawElements(gl.TRIANGLES, indices.length, gl.UNSIGNED_SHORT, 0);

	    if (clip === 1) {
		//gl.scissor(old_scissor[0], old_scissor[1], old_scissor[2], old_scissor[3]);
               gl.scissor(0, 0, renderTargetSize[0], renderTargetSize[1]);
	    }
        },
        wasm_cursor(name_ptr, name_len) {
            let cursor_name = utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, name_ptr, name_len));
            gl.canvas.style.cursor = cursor_name;
        },
        wasm_text_input(x, y, w, h) {
            if (w > 0 && h > 0) {
                textInputRect = [x, y, w, h];
            } else {
                textInputRect = [];
            }
        },
        wasm_open_url: (ptr, len) => {
            let msg = utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len));
            location.href = msg;
        },
        wasm_clipboardTextSet: (ptr, len) => {
            if (len == 0) {
                return;
            }

            let msg = utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len));
            if (navigator.clipboard) {
                navigator.clipboard.writeText(msg);
            } else {
                hidden_input.value = msg;
                hidden_input.focus();
                hidden_input.select();
                document.execCommand("copy");
                hidden_input.value = "";
                oskCheck();
            }
        },
        wasm_add_noto_font: () => {
            dvui_fetch("NotoSansKR-Regular.ttf").then((bytes) => {
                    //console.log("bytes len " + bytes.length);
                    const ptr = wasmResult.instance.exports.gpa_u8(bytes.length);
                    var dest = new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, bytes.length);
                    dest.set(bytes);
                    wasmResult.instance.exports.new_font(ptr, bytes.length);
            });
        },
        onExportCurrentSource: (ptr, len) => {
            if (len === 0) return;
            const content = utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len));
            console.log("compiled:")
            console.log(content)
            globalThis._monacoSyncHook?.(content);
            void downloadFile({
                fileName: "project.scm",
                content,
            });
        },

        onExportCompiled: (ptr, len) => {
            if (onExportCompiledOverride !== undefined) {
                onExportCompiledOverride(ptr, len);
                return;
            }
            if (len === 0) return;
            const content = utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len));
            void downloadFile({
                fileName: "compiled.wat",
                content,
            });
        },

        onRequestLoadSource() {
            uploadFile({ type: "text" }).then((file) => {
                const len = file.content.length;
                const ptr = wasmResult.instance.exports.graphl_init_start;
                const transferBuffer = () => new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len);
                {
                    const write = utf8encoder.encodeInto(file.content, transferBuffer());
                    assert(write.written === len, `failed to write file to transfer buffer`);
                }
                return wasmResult.instance.exports.onReceiveLoadedSource(ptr, len)
            });
        },

        onClickReportIssue() {
            window.open("https://docs.google.com/forms/d/e/1FAIpQLSf2dRcS7Nrv4Ut9GGmxIDVuIpzYnKR7CyHBMUkJQwdjenAXAA/viewform?usp=header", "_blank").focus();
        },

        runCurrentWat: async (ptr, len) => {
            if (len === 0) return;

            const data = new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len);

            const moduleBytes = compileWat_binaryen(data);

            let compiled;

            const scriptImports = {
                env: {
                    callUserFunc_R_vec3(func_id) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 0
                         || funcInfo.func.outputs.length !== 1
                         || funcInfo.func.outputs[0].type !== "vec3"
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`);

                        const __grappl_make_vec3 = wasmResult.instance.exports["__grappl_make_vec3"];
                        const { x, y, z } = funcInfo.func.impl();

                        return __grappl_make_vec3(x, y, z);
                    },

                    callUserFunc_JSON_R(func_id, json1) {
                        const funcInfo = userFuncs.get(func_id);

                        throw Error(`json not yet supported`);

                        return funcInfo.func.impl(json1);
                    },

                    callUserFunc_code_R(func_id, len, ptr) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 1
                         || funcInfo.func.inputs[0].type !== "code"
                         || funcInfo.func.outputs.length !== 0
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`);

                        const str = utf8decoder.decode(new Uint8Array(compiled.instance.exports.memory.buffer, ptr, len));
                        const code = JSON.parse(str);

                        funcInfo.func.impl(code);
                    },

                    callUserFunc_code_R_string(func_id, len, ptr) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 1
                         || funcInfo.func.inputs[0].type !== "code"
                         || funcInfo.func.outputs.length !== 1
                         || funcInfo.func.outputs[0].type !== "string"
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`);

                        const str = utf8decoder.decode(new Uint8Array(compiled.instance.exports.memory.buffer, ptr, len));
                        const code = JSON.parse(str);

                        const resultStr = funcInfo.func.impl(code);
                        // FIXME: actually return strings!
                        //utf8encoder.encodeInto(JSON.stringify(result), resultsBuffer());
                    },

                    callUserFunc_string_R(func_id, len, ptr) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 1
                         || funcInfo.func.inputs[0].type !== "string"
                         || funcInfo.func.outputs.length !== 0
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`);

                        const str = utf8decoder.decode(new Uint8Array(compiled.instance.exports.memory.buffer, ptr, len));
                        funcInfo.func.impl(str);
                    },

                    callUserFunc_R(func_id) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 0
                         || funcInfo.func.outputs.length !== 0
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`);

                        funcInfo.func.impl();
                    },

                    callUserFunc_i32_R(func_id, i1) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 1
                         || funcInfo.func.inputs[0].type !== "i32"
                         || funcInfo.func.outputs.length !== 0
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`);

                        funcInfo.func.impl(i1);
                    },

                    get callUserFunc_bool_R() { return this.callUserFunc_i32_R; },

                    callUserFunc_i32_R_i32(func_id, i1) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 1
                         || funcInfo.func.inputs[0].type !== "i32"
                         || funcInfo.func.outputs.length !== 1
                         || funcInfo.func.outputs[0].type !== "i32"
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`)

                        return funcInfo.func.impl(i1);
                    },

                    callUserFunc_i32_i32_R_i32(func_id, i1, i2) {
                        const funcInfo = userFuncs.get(func_id);

                        if (funcInfo === undefined
                         || funcInfo.func.inputs.length !== 2
                         || funcInfo.func.inputs[0].type !== "i32"
                         || funcInfo.func.inputs[1].type !== "i32"
                         || funcInfo.func.outputs.length !== 1
                         || funcInfo.func.outputs[0].type !== "i32"
                        ) throw Error(`bad user function #${func_id}(${funcInfo?.name})`)

                        return funcInfo.func.impl(i1, i2);
                    },
                },
            };

            compiled = await WebAssembly.instantiate(moduleBytes, scriptImports);
            lastCompiled = compiled;
            // FIXME: check return type of functions and read string pointers
            const result = compiled.instance.exports["main"]();

            console.log("exec result", result);
            const resultsBuffer = () => new Uint8Array(wasmResult.instance.exports.memory.buffer, wasmResult.instance.exports.result_buffer, 4096);

            utf8encoder.encodeInto(JSON.stringify(result), resultsBuffer());

            opts.onMainResult?.(result);
            wasmResult.instance.exports.dvui_refresh();
        },

        /** @param {number} handle */
        on_menu_click: (handle) => {
            menuOnClick.get(handle)?.();
        }
      },
    };

    WebAssembly.instantiateStreaming(fetch(frontendWasmUrl), imports)
    .then((_wasmResult) => {
        wasmResult = _wasmResult;
        const we = wasmResult.instance.exports;

        let nextMenuClickHandle = 0;
        /** @param {import("./WebBackend.d.ts").MenuOption[] | undefined} menus */
        function bindMenus(menus) {
            if (menus === undefined) return;
            for (const menu of menus) {
                const handle = nextMenuClickHandle;
                nextMenuClickHandle++;
                menuOnClick.set(handle, menu.onClick);
                menu.on_click_handle = handle;
                bindMenus(menu.submenus);
            }
        }

        bindMenus(opts.menus);

        /** @type {any} */
        const optsForWasm = { ...opts };
        let nextUserFuncHandle = 0;
        for (const userFuncKey in optsForWasm.userFuncs) {
            userFuncs.set(nextUserFuncHandle, {
                name: userFuncKey,
                func: {
                    inputs: opts.userFuncs[userFuncKey].inputs ?? [],
                    outputs: opts.userFuncs[userFuncKey].outputs ?? [],
                    impl: opts.userFuncs[userFuncKey].impl ?? (() => {}),
                },
            });
            optsForWasm.userFuncs[userFuncKey] = {
                id: nextUserFuncHandle++,
                node: {
                    ...opts.userFuncs[userFuncKey],
                    name: userFuncKey,
                    // FIXME: allow pure nodes
                    inputs: [{ name: "in", type: "exec" }, ...opts.userFuncs[userFuncKey].inputs ?? []],
                    outputs: [{ name: "out", type: "exec" }, ...opts.userFuncs[userFuncKey].outputs ?? []],
                },
            };
            delete optsForWasm.userFuncs[userFuncKey].node.impl;
        }

        const transferBuffer = () => new Uint8Array(
            wasmResult.instance.exports.memory.buffer,
            // FIXME: why is the end of the region exported? This doesn't seem to match what zig sees
            wasmResult.instance.exports.graphl_init_start - INIT_BUFFER_SZ,
            INIT_BUFFER_SZ,
        );

        // FIXME: remove debug
        globalThis._transferBuffer = transferBuffer;

        const optsJson = JSON.stringify(optsForWasm);

        {
            const write = utf8encoder.encodeInto(optsJson, transferBuffer());
            // TODO: add assert lib!
            if (write.read !== optsJson.length)
                throw Error(`options blob too large, max 1 WASM page size (16kB) allowed`);
        }


        const json_ptr = we.graphl_init_start - INIT_BUFFER_SZ;
        const json_len = optsJson.length;

        if (!we.setInitOpts(json_ptr, json_len)) {
            throw Error("error setting initialization options");
        }

        const canvas = canvasElem;

        let div = document.createElement("div");
        div.style.position = "relative";
        div.style.opacity = 0;
        div.style.zIndex = -1;
        //div.style.width = 0;
        //div.style.height = 0;
        //div.style.overflow = "hidden";
        hidden_input = document.createElement("input");
        hidden_input.classList.add("dvui-hidden-input");
       hidden_input.style.position = "absolute";
       hidden_input.style.left = (window.scrollX + canvas.getBoundingClientRect().left) + "px";
       hidden_input.style.top = (window.scrollY + canvas.getBoundingClientRect().top) + "px";
        div.appendChild(hidden_input);
        document.body.prepend(div);

        //let par = document.createElement("p");
        //document.body.prepend(par);
        //par.textContent += window.devicePixelRatio;

        gl = canvas.getContext("webgl2", { alpha: true });
        if (gl === null) {
            webgl2 = false;
            gl = canvas.getContext("webgl", { alpha: true });
        }

        if (gl === null) {
            alert("Unable to initialize WebGL.");
            return;
        }

        if (!webgl2) {
            const ext = gl.getExtension("OES_element_index_uint");
            if (ext === null) {
                alert("WebGL doesn't support OES_element_index_uint.");
                return;
            }
        }

       frame_buffer = gl.createFramebuffer();

        const vertexShader = gl.createShader(gl.VERTEX_SHADER);
        if (webgl2) {
            gl.shaderSource(vertexShader, vertexShaderSource_webgl2);
        } else {
            gl.shaderSource(vertexShader, vertexShaderSource_webgl);
        }
        gl.compileShader(vertexShader);
        if (!gl.getShaderParameter(vertexShader, gl.COMPILE_STATUS)) {
            alert(`Error compiling vertex shader: ${gl.getShaderInfoLog(vertexShader)}`);
            gl.deleteShader(vertexShader);
            return null;
        }

        const fragmentShader = gl.createShader(gl.FRAGMENT_SHADER);
        if (webgl2) {
            gl.shaderSource(fragmentShader, fragmentShaderSource_webgl2);
        } else {
            gl.shaderSource(fragmentShader, fragmentShaderSource_webgl);
        }
        gl.compileShader(fragmentShader);
        if (!gl.getShaderParameter(fragmentShader, gl.COMPILE_STATUS)) {
            alert(`Error compiling fragment shader: ${gl.getShaderInfoLog(fragmentShader)}`);
            gl.deleteShader(fragmentShader);
            return null;
        }

        shaderProgram = gl.createProgram();
        gl.attachShader(shaderProgram, vertexShader);
        gl.attachShader(shaderProgram, fragmentShader);
        gl.linkProgram(shaderProgram);

        if (!gl.getProgramParameter(shaderProgram, gl.LINK_STATUS)) {
            alert(`Error initializing shader program: ${gl.getProgramInfoLog(shaderProgram)}`);
            return null;
        }

        programInfo = {
            attribLocations: {
                vertexPosition: gl.getAttribLocation(shaderProgram, "aVertexPosition"),
                vertexColor: gl.getAttribLocation(shaderProgram, "aVertexColor"),
                textureCoord: gl.getAttribLocation(shaderProgram, "aTextureCoord"),
            },
            uniformLocations: {
                matrix: gl.getUniformLocation(shaderProgram, "uMatrix"),
                uSampler: gl.getUniformLocation(shaderProgram, "uSampler"),
                useTex: gl.getUniformLocation(shaderProgram, "useTex"),
            },
        };

        indexBuffer = gl.createBuffer();
        vertexBuffer = gl.createBuffer();

        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        gl.enable(gl.SCISSOR_TEST);
        gl.scissor(0, 0, gl.canvas.clientWidth, gl.canvas.clientHeight);

        let renderRequested = false;
        let renderTimeoutId = 0;
        let app_initialized = false;

        function render() {
            renderRequested = false;

            // if the canvas changed size, adjust the backing buffer
            const w = gl.canvas.clientWidth;
            const h = gl.canvas.clientHeight;
            const scale = window.devicePixelRatio;
            //console.log("wxh " + w + "x" + h + " scale " + scale);
            gl.canvas.width = Math.round(w * scale);
            gl.canvas.height = Math.round(h * scale);
           renderTargetSize = [gl.drawingBufferWidth, gl.drawingBufferHeight];
            gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
            gl.scissor(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);

            gl.clearColor(0.0, 0.0, 0.0, 1.0); // Clear to black, fully opaque
            gl.clear(gl.COLOR_BUFFER_BIT);

            if (!app_initialized) {
                app_initialized = true;
	        let app_init_return = 0;
	        let str = utf8encoder.encode(navigator.platform);
                if (str.length > 0) {
                    const ptr = wasmResult.instance.exports.gpa_u8(str.length);
                    var dest = new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, str.length);
                    dest.set(str);
                    app_init_return = wasmResult.instance.exports.app_init(ptr, str.length);
		    wasmResult.instance.exports.gpa_free(ptr, str.length);
		} else {
                    app_init_return = wasmResult.instance.exports.app_init(0, 0);
		}

		if (app_init_return != 0) {
		    console.log("ERROR: app_init returned " + app_init_return);
		    return;
		}
            }

            let millis_to_wait = wasmResult.instance.exports.app_update();
            if (millis_to_wait == 0) {
                requestRender();
            } else if (millis_to_wait > 0) {
                renderTimeoutId = setTimeout(function () { renderTimeoutId = 0; requestRender(); }, millis_to_wait);
            }
            // otherwise something went wrong, so stop
        }

        function requestRender() {
            if (renderTimeoutId > 0) {
                // we got called before the timeout happened
                clearTimeout(renderTimeoutId);
                renderTimeoutId = 0;
            }

            if (!renderRequested) {
                // multiple events could call requestRender multiple times, and
                // we only want a single requestAnimationFrame to happen before
                // each call to app_update
                renderRequested = true;
                requestAnimationFrame(render);
            }
        }

        // event listeners
        canvas.addEventListener("contextmenu", (ev) => {
            ev.preventDefault();
        });
        window.addEventListener("resize", (ev) => {
            requestRender();
        });
        canvas.addEventListener("mousemove", (ev) => {
            let rect = canvas.getBoundingClientRect();
            let x = (ev.clientX - rect.left) / (rect.right - rect.left) * canvas.clientWidth;
            let y = (ev.clientY - rect.top) / (rect.bottom - rect.top) * canvas.clientHeight;
            wasmResult.instance.exports.add_event(1, 0, 0, x, y);
            requestRender();
        });
        canvas.addEventListener("mousedown", (ev) => {
            wasmResult.instance.exports.add_event(2, ev.button, 0, 0, 0);
            requestRender();
        });
        canvas.addEventListener("mouseup", (ev) => {
            wasmResult.instance.exports.add_event(3, ev.button, 0, 0, 0);
            requestRender();
            oskCheck();
        });
        canvas.addEventListener("wheel", (ev) => {
            // NOTE: future versions of dvui will probably check at the end of the frame
            // if any events weren't handled by dvui and re-dispatch an appropriate unhandled event
            // making this unnecessary
            ev.preventDefault();
            wasmResult.instance.exports.add_event(4, 0, 0, ev.deltaY, 0);
            requestRender();
        });

        let keydown = function(ev) {
            // stop tab from tabbing away from the canvas
            if (ev.key == "Tab") ev.preventDefault();
            // stop F5 from refreshing the page
            if (ev.key == "F5") ev.preventDefault();

            let str = utf8encoder.encode(ev.key);
            if (str.length > 0) {
                const ptr = wasmResult.instance.exports.arena_u8(str.length);
                var dest = new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, str.length);
                dest.set(str);
                wasmResult.instance.exports.add_event(5, ptr, str.length, ev.repeat, (ev.metaKey << 3) + (ev.altKey << 2) + (ev.ctrlKey << 1) + (ev.shiftKey << 0));
                requestRender();
            }
        };
        canvas.addEventListener("keydown", keydown);
        hidden_input.addEventListener("keydown", keydown);

        let keyup = function(ev) {
            const str = utf8encoder.encode(ev.key);
            const ptr = wasmResult.instance.exports.arena_u8(str.length);
            var dest = new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, str.length);
            dest.set(str);
            wasmResult.instance.exports.add_event(6, ptr, str.length, 0, (ev.metaKey << 3) + (ev.altKey << 2) + (ev.ctrlKey << 1) + (ev.shiftKey << 0));
            requestRender();
        };
        canvas.addEventListener("keyup", keyup);
        hidden_input.addEventListener("keyup", keyup);

        hidden_input.addEventListener("beforeinput", (ev) => {
            ev.preventDefault();
            if (ev.data) {
                const str = utf8encoder.encode(ev.data);
                const ptr = wasmResult.instance.exports.arena_u8(str.length);
                var dest = new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, str.length);
                dest.set(str);
                wasmResult.instance.exports.add_event(7, ptr, str.length, 0, 0);
                requestRender();
            }
        });
        canvas.addEventListener("touchstart", (ev) => {
            ev.preventDefault();
            let rect = canvas.getBoundingClientRect();
            for (let i = 0; i < ev.changedTouches.length; i++) {
                let touch = ev.changedTouches[i];
                let x = (touch.clientX - rect.left) / (rect.right - rect.left);
                let y = (touch.clientY - rect.top) / (rect.bottom - rect.top);
                let tidx = touchIndex(touch.identifier);
                wasmResult.instance.exports.add_event(8, touches[tidx][1], 0, x, y);
            }
            requestRender();
        });
        canvas.addEventListener("touchend", (ev) => {
            ev.preventDefault();
            let rect = canvas.getBoundingClientRect();
            for (let i = 0; i < ev.changedTouches.length; i++) {
                let touch = ev.changedTouches[i];
                let x = (touch.clientX - rect.left) / (rect.right - rect.left);
                let y = (touch.clientY - rect.top) / (rect.bottom - rect.top);
                let tidx = touchIndex(touch.identifier);
                wasmResult.instance.exports.add_event(9, touches[tidx][1], 0, x, y);
                touches.splice(tidx, 1);
            }
            requestRender();
            oskCheck();
        });
        canvas.addEventListener("touchmove", (ev) => {
            ev.preventDefault();
            let rect = canvas.getBoundingClientRect();
            for (let i = 0; i < ev.changedTouches.length; i++) {
                let touch = ev.changedTouches[i];
                let x = (touch.clientX - rect.left) / (rect.right - rect.left);
                let y = (touch.clientY - rect.top) / (rect.bottom - rect.top);
                let tidx = touchIndex(touch.identifier);
                wasmResult.instance.exports.add_event(10, touches[tidx][1], 0, x, y);
            }
            requestRender();
        });
        //canvas.addEventListener("touchcancel", (ev) => {
        //    console.log(ev);
        //    requestRender();
        //});

        // start the first update
        requestRender();
    });

    /** @type {Promise<any>} */
    let wabtPromise;
    if (!(opts.preferences?.compiler.watOnly ?? false)) {
        // old binaryen code
        import("./zig-out/bin/wasm-opt.js")
            .then(s => s.default())
            .then((mod) => {
                globalThis._wasmOpt = mod;
                // FIXME: save the promise so there isn't a race!
                wasmOpt = mod;
            });

        /*
        // TODO: use wabt
        const libWabtScript = document.createElement("script");
        // FIXME: make async with onload
        libWabtScript.src = "/graphl-demo/zig-out/bin/libwabt.js";
        wabtPromise = new Promise((resolve) => libWabtScript.onload = () => {
          globalThis.WabtModule().then((wabt) => {
              globalThis._wabt = wabt;
              resolve(wabt);
          });
        });
        document.body.append(libWabtScript);
        */
    }

    return {
        functions: new Proxy({}, {
            get(_target, key, _receiver) {
                if (typeof key !== "string")
                    throw Error("function names are strings");
                //if (!lastCompiled) {
                // fix compilation to allow specific function execution!
                return wasmResult?.instance.exports._runCurrentGraphs;
                //}
                //return lastCompiled?.instance.exports?.[key];
            }
        }),
        async exportCompiled() {
            let content;
            const original = onExportCompiledOverride;
            onExportCompiledOverride = (ptr, len) => {
                content = utf8decoder.decode(new Uint8Array(wasmResult.instance.exports.memory.buffer, ptr, len));
            };
            wasmResult.instance.exports.exportCurrentCompiled();
            onExportCompiledOverride = original;
            return compileWat_binaryen(content);
        }
    };
}
