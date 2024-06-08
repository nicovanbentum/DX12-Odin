package main

DDS_FOURCC :: bit_field u32 
{
    ch0 : u8 | 8,
    ch1 : u8 | 8,
    ch2 : u8 | 8,
    ch3 : u8 | 8
}

DDS_FORMAT_DX10 := DDS_FOURCC {ch0 = 'D', ch1 = 'X', ch2 = '1', ch3 = '0'}
DDS_FORMAT_DXT1 := DDS_FOURCC {ch0 = 'D', ch1 = 'X', ch2 = 'T', ch3 = '1'}
DDS_FORMAT_DXT2 := DDS_FOURCC {ch0 = 'D', ch1 = 'X', ch2 = 'T', ch3 = '2'}
DDS_FORMAT_DXT3 := DDS_FOURCC {ch0 = 'D', ch1 = 'X', ch2 = 'T', ch3 = '3'}
DDS_FORMAT_DXT4 := DDS_FOURCC {ch0 = 'D', ch1 = 'X', ch2 = 'T', ch3 = '4'}
DDS_FORMAT_DXT5 := DDS_FOURCC {ch0 = 'D', ch1 = 'X', ch2 = 'T', ch3 = '5'}
DDS_FORMAT_ATI1 := DDS_FOURCC {ch0 = 'A', ch1 = 'T', ch2 = 'I', ch3 = '1'}
DDS_FORMAT_ATI2 := DDS_FOURCC {ch0 = 'A', ch1 = 'T', ch2 = 'I', ch3 = '2'}

DDS_PIXEL_FORMAT_FLAGS :: enum 
{
    ALPHAPIXELS = 0x1,
    ALPHA = 0x2,
    FOURCC = 0x4,
    RGB = 0x40,
    YUV = 0x200,
    LUMINANCE = 0x20000
}

DDS_MAGIC_NUMBER :: 0x20534444

DDS_PIXEL_FORMAT :: struct
{
    Size : u32,
    Flags : u32,
    FourCC : u32,
    RGBBitCount : u32,
    RBitMask : u32,
    GBitMask : u32,
    BBitMask : u32,
    ABitMask : u32
}

DDS_FLAGS :: enum
{
	CAPS = 0x1,
	HEIGHT = 0x2,
	WIDTH = 0x4,
	PITCH = 0x8,
	PIXELFORMAT = 0x1000,
	MIPMAPCOUNT = 0x20000,
	LINEARSIZE = 0x80000,
	DEPTH = 0x800000
}

DDS_CAPS :: enum
{
	COMPLEX = 0x8,
	MIPMAP = 0x400000,
	TEXTURE = 0x1000
}

DDS_CAPS2 :: enum
{
	DDSCAPS2_CUBEMAP = 0x200,
	DDSCAPS2_CUBEMAP_POSITIVEX = 0x400,
	DDSCAPS2_CUBEMAP_NEGATIVEX = 0x800,
	DDSCAPS2_CUBEMAP_POSITIVEY = 0x1000,
	DDSCAPS2_CUBEMAP_NEGATIVEY = 0x2000,
	DDSCAPS2_CUBEMAP_POSITIVEZ = 0x4000,
	DDSCAPS2_CUBEMAP_NEGATIVEZ = 0x8000,
	DDSCAPS2_VOLUME = 0x200000
}

DDS_HEADER :: struct 
{
	 dwSize : u32,
	 dwFlags : u32,
	 dwHeight : u32,
	 dwWidth : u32,
	 dwPitchOrLinearSize : u32,
	 dwDepth : u32,
	 dwMipMapCount : u32,
	 dwReserved1 : [11]u32,
	 ddspf : DDS_PIXEL_FORMAT,
	 dwCaps : u32,
	 dwCaps2 : u32,
	 dwCaps3 : u32,
	 dwCaps4 : u32,
	 dwReserved2 : u32
}

DDS_HEADER_DXT10 :: struct
{
	dxgiFormat : u32,
	resourceDimension : u32,
	miscFlag : u32,
	arraySize : u32,
	miscFlags2 : u32
}

DDS_FILE_INFO :: struct
{
    magicNumber : u32,
    header : DDS_HEADER
}

DDS_FILE_INFO_EXTENDED :: struct
{
    magicNumber : u32,
    header : DDS_HEADER,
    header10 : DDS_HEADER_DXT10
}