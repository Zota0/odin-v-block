package cbind

import "core:c"
import "base:runtime"
import "core:strings"

foreign import lib "rightpad.lib"

@(default_calling_convention="c")
foreign lib {
    right_pad :: proc(str: cstring, len: c.int, ch: c.char) -> cstring ---
}

RightPad :: proc(str: string, length: i32, ch: string) -> string {
    if len(ch) == 0 {
        return str
    }
    
    // Convert Odin string to C string
    c_str := strings.unsafe_string_to_cstring(str)
    
    // Convert length to C int
    c_len := c.int(length)
    
    // Take first character from ch string and convert to C char
    c_ch := c.char(ch[0])
    
    // Call the C function
    result := right_pad(c_str, c_len, c_ch)
    
    // Convert the result back to Odin string
    odin_str := string(runtime.cstring_to_string(result))
    
    // Free the C string result if necessary
    // Note: Only free if the C implementation allocates new memory
    // c.free(raw_data(result))
    
    return odin_str
}