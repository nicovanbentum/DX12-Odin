package main

import "core:sys/windows"

os_open_file_dialog :: proc(filters : windows.wstring) -> (path : string, success : bool)
{
    data : [260]windows.WCHAR

    ofn : windows.OPENFILENAMEW = {
        lStructSize = size_of(windows.OPENFILENAMEW),
        hwndOwner = windows.GetActiveWindow(),
        lpstrFile = raw_data(data[:]),
        nMaxFile = windows.DWORD(size_of(data)),
        lpstrFilter = filters,
        nFilterIndex = 1,
        Flags = windows.OFN_PATHMUSTEXIST | windows.OFN_FILEMUSTEXIST | windows.OFN_NOCHANGEDIR
    }
    
    if windows.GetOpenFileNameW(&ofn) == windows.TRUE {
        path, result := windows.utf16_to_utf8(data[:])

        if result == .None {
            return path, true
        }
        
        return "", false
    }

    return "", false
}

os_save_file_dialog :: proc(filters : windows.wstring, ext : windows.wstring) -> (path : string, success : bool)
{
    data : [260]windows.WCHAR

    ofn : windows.OPENFILENAMEW = {
        lStructSize = size_of(windows.OPENFILENAMEW),
        hwndOwner = windows.GetActiveWindow(),
        lpstrFile = raw_data(data[:]),
        nMaxFile = windows.DWORD(size_of(data)),
        lpstrFilter = filters,
        nFilterIndex = 1,
        lpstrDefExt = ext,
        Flags = windows.OFN_PATHMUSTEXIST | windows.OFN_FILEMUSTEXIST | windows.OFN_NOCHANGEDIR
    }
    
    if windows.GetSaveFileNameW(&ofn) == windows.TRUE {
        path, result := windows.utf16_to_utf8(data[:])

        if result == .None {
            return path, true
        }
        
        return "", false
    }

    return "", false
}