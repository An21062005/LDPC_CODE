from pathlib import Path
import hashlib
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / 'source_report.docx'
OUTPUT = ROOT.parent / 'Bao_cao_kiem_tra_sua_loi_RTL_LDPC_bo_sung_thu_tu_codeword_v3.docx'
WORK = ROOT.parents[1]

expected = (WORK/'FINAL_REPORT_PACKAGE/results/expected_codeword.txt').read_text().splitlines()
ordered = (WORK/'verification/codeword_order/output_codeword.txt').read_text().splitlines()
assert len(expected) == len(ordered) == 696
assert all(len(x) == 1152 for x in expected)
assert expected == ordered
raw = (WORK/'FINAL_REPORT_PACKAGE/results/output_fixed_full_board.txt').read_text().splitlines()
assert raw[0][:48] == '101011010111111111111111100111100111111111000011'
assert expected[0][:48] == '110100011110110101011100111111110010000011001100'
for filename, phrase in [
    ('codeword_order_xsim.log', 'PASS: direct RTL AXI codeword output matched 696 frames / 801792 bits'),
    ('codeword_full_core_xsim.log', 'PASS: AXI wrapper loaded 3 frames and matched all 1152 output bits'),
]:
    assert phrase in (WORK/'verification/codeword_order'/filename).read_text()

doc = Document(SOURCE)
original_document = Document(SOURCE)
original_nodes = [x for x in original_document._element.body if x.tag != qn('w:sectPr')]
original_media = {p.partname: hashlib.sha256(p.blob).hexdigest() for p in doc.part.package.parts if '/media/' in str(p.partname)}

def font(run, size=12, bold=False, mono=False):
    run.font.name = 'Consolas' if mono else 'Times New Roman'
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = RGBColor(0, 0, 0)
    for attr in ('ascii', 'hAnsi', 'eastAsia', 'cs'):
        run._element.get_or_add_rPr().rFonts.set(qn('w:'+attr), run.font.name)

def paragraph(text='', size=12, bold=False, mono=False, keep=False):
    p = doc.add_paragraph(style='Normal')
    p.paragraph_format.space_before = Pt(0)
    p.paragraph_format.space_after = Pt(5)
    p.paragraph_format.line_spacing = 1.05
    p.paragraph_format.keep_with_next = keep
    p.paragraph_format.widow_control = True
    font(p.add_run(text), size, bold, mono)
    return p

def heading(text, level=2):
    p = doc.add_paragraph(style='Heading '+str(level))
    p.paragraph_format.space_before = Pt(7)
    p.paragraph_format.space_after = Pt(5)
    p.paragraph_format.keep_with_next = True
    p.paragraph_format.keep_together = True
    font(p.add_run(text), 14 if level == 1 else 12, True)
    return p

def code(text):
    p = paragraph(text, size=9, mono=True)
    p.alignment = WD_ALIGN_PARAGRAPH.LEFT
    p.paragraph_format.line_spacing = 1.0
    p.paragraph_format.keep_together = True
    p.paragraph_format.left_indent = Cm(.15)
    shade = OxmlElement('w:shd'); shade.set(qn('w:fill'), 'F2F2F2')
    p._element.get_or_add_pPr().append(shade)
    return p

def table(headers, rows, widths):
    t=doc.add_table(rows=1, cols=len(headers))
    t.style='Table Grid'
    t.autofit=False
    for col,w in zip(t.columns,widths): col.width=Cm(w)
    for cell,text,w in zip(t.rows[0].cells,headers,widths):
        cell.width=Cm(w)
        p=cell.paragraphs[0]; p.paragraph_format.space_after=Pt(3); p.paragraph_format.space_before=Pt(3)
        font(p.add_run(text),11,True)
        shade=OxmlElement('w:shd'); shade.set(qn('w:fill'),'E7E6E6'); cell._tc.get_or_add_tcPr().append(shade)
    repeat=OxmlElement('w:tblHeader'); t.rows[0]._tr.get_or_add_trPr().append(repeat)
    for row in rows:
        cells=t.add_row().cells
        for cell,text,w in zip(cells,row,widths):
            cell.width=Cm(w)
            p=cell.paragraphs[0]; p.paragraph_format.space_after=Pt(3); p.paragraph_format.space_before=Pt(3)
            p.paragraph_format.line_spacing=1.0
            font(p.add_run(text),11)
    for row in t.rows:
        tag=OxmlElement('w:cantSplit'); row._tr.get_or_add_trPr().append(tag)
    return t

doc.add_page_break()
heading('Bổ sung chỉnh RTL để output đúng thứ tự codeword',1)
paragraph('Cập nhật ngày 07 tháng 10 năm 2026',10)
paragraph('Wrapper AXI đã được chỉnh để ARM đọc trực tiếp 1152 bit theo thứ tự của expected_codeword.txt. Phần bổ sung này mô tả thay đổi cách xuất dữ liệu và kết quả xác minh của phiên bản COD1; các phần và ảnh kết quả phía trước thuộc bản báo cáo trước khi bổ sung.')

heading('Nguyên nhân hai file có chuỗi bit đầu khác nhau')
paragraph('Bản cũ lưu hard decision theo 32 địa chỉ, mỗi địa chỉ có 36 lane PE, rồi xuất lần lượt từng block 36 bit. Reference lại xếp theo cột PE, hàng PE, rồi 32 địa chỉ của PE đó. Vì thứ tự duyệt khác nhau, hai chuỗi có thể khác ngay từ bit đầu dù cùng chứa các quyết định giải mã.')
paragraph('Ví dụ 48 bit đầu của frame thứ nhất trong dữ liệu kiểm tra:',11,keep=True)
code('Output raw cũ:  '+raw[0][:48]+'\nExpected:      '+expected[0][:48]+'\nOutput RTL mới: '+ordered[0][:48])

heading('Ánh xạ bit được thực hiện trong phần cứng')
paragraph('File sửa: fixed_rtl_source/LDPC_Decoder_PYNQ_Z2_top.sv. Với K = 6, L = 32, chỉ số q chạy từ 0 đến 35 theo cột rồi hàng; b chạy từ 0 đến 31 theo địa chỉ. Bus output_codeword được nối bằng các chỉ số hằng khi elaboration:',11)
code('for (genvar q = 0; q < K*K; q = q + 1) begin\n  for (genvar b = 0; b < L; b = b + 1) begin\n    assign output_codeword[q*L+b] =\n        output_blocks[b][(q%K)*K+q/K];\n  end\nend')
paragraph('Ví dụ: 32 bit đầu lấy từ lane 0 ở địa chỉ 0 đến 31; 32 bit kế tiếp lấy từ lane 6 ở địa chỉ 0 đến 31. Giá trị bit không bị sửa và RTL không chứa dữ liệu expected. Thuật toán trong Decoder.v được giữ nguyên trong lần chỉnh thứ tự này.',11)

heading('Đọc codeword qua AXI4 Lite')
paragraph('Số lần đọc vẫn là 32 chunk × 36 bit. Mỗi chunk ghép 32 bit thấp với 4 bit cao; phần mềm xuất từ bit thấp đến bit cao.',11)
table(['Offset','Chức năng ở bản COD1'],[
    ('0x10','OUTPUT_ADDR chọn chunk 0 đến 31.'),
    ('0x14 / 0x18','OUTPUT_LO trả 32 bit; OUTPUT_HI trả 4 bit kế tiếp ở [3:0], các bit còn lại bằng 0.'),
    ('0x20','OUTPUT_FORMAT trả 0x434F4431, mã ASCII COD1, để nhận diện bitstream có output đã xếp đúng thứ tự.'),
],[2.6,13.9])

doc.add_page_break()
heading('Xác minh phiên bản xuất codeword COD1',1)
paragraph('Các phép thử dưới đây kiểm tra trực tiếp bit đọc ra từ wrapper AXI. Reference chỉ được dùng để so sánh trong testbench hoặc Python; không được dùng để sinh hay thay thế output của RTL.')
table(['Phép thử','Phạm vi và kết quả'],[
    ('Kiểm tra ánh xạ và đọc AXI','Nạp lại 696 frame raw đã ghi từ board vào bộ đệm capture của wrapper, đọc qua AXI thật của RTL mới và so trực tiếp với reference: 801.792 bit, 0 bit sai, PASS.'),
    ('Chạy core với input thật','Nạp 3 frame LLR qua AXI và chạy core: 2 transaction đầu khởi động/flush; output hợp lệ đầu tiên khớp toàn bộ 1152 bit, PASS.'),
    ('So sánh file trực tiếp','File output_codeword.txt do mô phỏng RTL xuất có 696 frame, giống reference từng bit. Không thực hiện hoán vị output trong bước so sánh.'),
],[4.4,12.1])
paragraph('Phép thử 696 frame là kiểm tra ánh xạ và đường đọc từ dữ liệu capture có sẵn, không phải chạy lại toàn bộ decoder với 698 input mới. Chạy end-to-end trên PYNQ-Z2 bằng bitstream COD1 vẫn cần thực hiện sau khi build và nạp FPGA.',11)
paragraph('Log xác minh trong verification/codeword_order/:',11,keep=True)
code('codeword_order_xsim.log\nPASS: direct RTL AXI codeword output matched\n      696 frames / 801792 bits\ncodeword_full_core_xsim.log\nPASS: AXI wrapper loaded 3 frames and matched\n      all 1152 output bits')

heading('Cập nhật Python và các file kết quả')
paragraph('Mọi đường dẫn dưới đây tính từ pynq_z2_shared_work/.',10)
paragraph('board_uploads/run_ldpc_full_benchmark.py kiểm tra OUTPUT_FORMAT trước khi chạy và dừng nếu FPGA chưa dùng COD1. Script ghép bit từ các thanh ghi AXI rồi ghi output_codeword.txt; không còn chuyển thứ tự raw sang codeword bằng Python.',11)
paragraph('tools/compare_board_to_clean.py so trực tiếp output_codeword.txt với FINAL_REPORT_PACKAGE/results/expected_codeword.txt. Hai đường dẫn EXPECTED và ACTUAL nằm ở đầu script để cấu hình. summary.json ghi output_order = codeword và output_format = COD1; transactions.csv lưu số đo từng transaction.',11)
paragraph('output_fixed_full_board.txt và output_raw.txt của các lần chạy cũ vẫn mang thứ tự raw. Các file đó là dữ liệu lịch sử và không dùng cho phép so trực tiếp của bản COD1.',11)

heading('Các bước xác nhận trên board sau khi build')
paragraph('1. Build project fixed_hw_project_v2/ldpc_pynq_z2_axi_fixed_v2.xpr với top ldpc_system_wrapper. Nạp file ldpc_system_wrapper.bit mới vào FPGA qua JTAG.',11)
paragraph('2. Gửi runner Python đã cập nhật lên board, chạy benchmark và lấy thư mục kết quả mới về máy bằng các công cụ UART hiện có.',11)
paragraph('3. Đặt ACTUAL trỏ tới output_codeword.txt vừa tải, giữ EXPECTED trỏ tới reference rồi chạy lệnh sau từ thư mục gốc repository:',11,keep=True)
code('python .\\pynq_z2_shared_work\\tools\\compare_board_to_clean.py')
paragraph('4. Ghi nhận OUTPUT_FRAMES = 696, BIT_ERRORS = 0 và RESULT = PASS nếu lần chạy mới đạt. Đồng thời kiểm tra báo cáo timing và tài nguyên của chính bitstream COD1; số liệu và ảnh của bản cũ không xác nhận timing hoặc hiệu năng của bản mới.',11)

doc.core_properties.title='Kiểm tra và sửa lỗi RTL LDPC bổ sung thứ tự codeword'
doc.core_properties.subject='Bổ sung ánh xạ output trong wrapper AXI và xác minh COD1'
assert OUTPUT.parent == ROOT.parent and OUTPUT != SOURCE
doc.save(OUTPUT)

# Preserve all supplied text, tables, equations, images and formatting.
check=Document(OUTPUT)
new_nodes=[x for x in check._element.body if x.tag != qn('w:sectPr')]
from lxml import etree
assert all(etree.tostring(a)==etree.tostring(b) for a,b in zip(original_nodes,new_nodes))
new_media={p.partname:hashlib.sha256(p.blob).hexdigest() for p in check.part.package.parts if '/media/' in str(p.partname)}
assert original_media==new_media
print('OUTPUT='+str(OUTPUT))
print('PRESERVED_ORIGINAL_NODES='+str(len(original_nodes)))
print('PRESERVED_IMAGES='+str(len(original_media)))
print('DIRECT_REFERENCE_CHECK=696 frames / 801792 bits / 0 bit errors')
