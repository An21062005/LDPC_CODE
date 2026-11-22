%% build_ldpc_580_1152.m
% Tao model Simulink:
% 580-bit payload -> LDPC Encoder -> 1152-bit codeword -> To Workspace
%
% Payload:
%   36 bit dau = 36'hA5A5A5A5A
%   544 bit sau = 0
%
% Neu workspace da co bien H (572x1152), script se dung H do.
% Neu chua co H, script tao H_demo = [A I] de TEST LUONG SIMULINK.
% H_demo KHONG PHAI ma LDPC (3,6) cua RTL cua ban.
%
% Yeu cau: Simulink + Communications Toolbox.

clearvars -except H
clc

%% 1) Tao payload 580 bit
bits36 = dec2bin(hex2dec('A5A5A5A5A'), 36) - '0';
payload = [bits36(:); zeros(544,1)];

assert(numel(payload) == 580, 'Payload phai co dung 580 bit.');
payload = double(payload);

%% 2) Chon parity-check matrix H
K = 580;
N = 1152;
M = N - K;   % 572 parity-check bits

if exist('H','var')
    assert(isequal(size(H), [M N]), ...
        'H phai co kich thuoc 572x1152 cho K=580, N=1152.');
    H_used = sparse(logical(H));
    fprintf('Dang dung H co san trong workspace: %dx%d\n', size(H_used,1), size(H_used,2));
else
    % H demo: [A I]
    % Tao A sparse voi 3 canh cho moi information bit.
    rows = zeros(3*K,1);
    cols = zeros(3*K,1);
    p = 1;

    for j = 1:K
        cand = [ ...
            mod(j-1, M)+1, ...
            mod(7*(j-1)+11, M)+1, ...
            mod(13*(j-1)+29, M)+1];

        % Dam bao 3 row khac nhau
        while numel(unique(cand)) < 3
            cand(3) = mod(cand(3), M) + 1;
        end

        rows(p:p+2) = cand(:);
        cols(p:p+2) = j;
        p = p + 3;
    end

    A = sparse(rows, cols, true, M, K);
    H_used = [A speye(M)];

    warning(['Chua co H that. Dang dung H_demo=[A I] chi de test ' ...
             '580 -> 1152 trong Simulink. H_demo KHONG phai ma (3,6) cua RTL.']);
end

assignin('base','payload',payload);
assignin('base','H_used',H_used);

%% 3) Tao model
model = 'ldpc_580_1152_demo';

if bdIsLoaded(model)
    close_system(model,0);
end

if exist([model '.slx'],'file')
    delete([model '.slx']);
end

new_system(model);
open_system(model);

set_param(model, ...
    'SolverType','Fixed-step', ...
    'Solver','FixedStepDiscrete', ...
    'FixedStep','1', ...
    'StopTime','0');

%% 4) Them cac block co ban
add_block('simulink/Sources/Constant', [model '/Payload_580bit'], ...
    'Value','payload', ...
    'SampleTime','1', ...
    'Position',[60 110 180 160]);

add_block('simulink/Sinks/To Workspace', [model '/Save_Codeword'], ...
    'VariableName','codeword', ...
    'SaveFormat','Array', ...
    'Position',[520 110 650 160]);

%% 5) Tim LDPC Encoder trong Communications Toolbox
ldpcLib = '';

% Cach 1: thu library path thuong dung
try
    load_system('commblkcod2');
    cands = find_system('commblkcod2', ...
        'LookUnderMasks','all', ...
        'FollowLinks','on', ...
        'Name','LDPC Encoder');
    if ~isempty(cands)
        ldpcLib = cands{1};
    end
catch
end

% Cach 2: thu mot so path pho bien
if isempty(ldpcLib)
    commonPaths = { ...
        'commblkcod2/LDPC Encoder', ...
        'commblkcod2/LDPC Encoder Baseband'};
    for i = 1:numel(commonPaths)
        try
            get_param(commonPaths{i},'Handle');
            ldpcLib = commonPaths{i};
            break;
        catch
        end
    end
end

if isempty(ldpcLib)
    error([ ...
        'Khong tim thay block "LDPC Encoder". ' ...
        'Kiem tra Communications Toolbox da cai chua. ' ...
        'Neu da cai, mo Library Browser -> Communications Toolbox -> ' ...
        'Error Detection and Correction -> Block -> LDPC Encoder.']);
end

add_block(ldpcLib, [model '/LDPC_Encoder'], ...
    'Position',[280 100 420 170]);

%% 6) Gan parameter Parity-check matrix = H_used
blk = [model '/LDPC_Encoder'];
dp = get_param(blk,'DialogParameters');
paramNames = fieldnames(dp);

pcmParam = '';
for i = 1:numel(paramNames)
    info = dp.(paramNames{i});
    prompt = '';
    if isfield(info,'Prompt')
        prompt = info.Prompt;
    end
    if contains(lower(prompt),'parity') && contains(lower(prompt),'matrix')
        pcmParam = paramNames{i};
        break;
    end
end

% Fallback cho mot so version
if isempty(pcmParam)
    fallbackNames = {'ParityCheckMatrix','H','parityCheckMatrix'};
    for i = 1:numel(fallbackNames)
        if isfield(dp,fallbackNames{i})
            pcmParam = fallbackNames{i};
            break;
        end
    end
end

if isempty(pcmParam)
    error('Khong tim thay parameter Parity-check matrix cua block LDPC Encoder.');
end

set_param(blk, pcmParam, 'H_used');

%% 7) Noi day
add_line(model,'Payload_580bit/1','LDPC_Encoder/1','autorouting','on');
add_line(model,'LDPC_Encoder/1','Save_Codeword/1','autorouting','on');

%% 8) Sap xep + luu
try
    Simulink.BlockDiagram.arrangeSystem(model);
catch
end

save_system(model);

fprintf('\nDa tao: %s.slx\n', model);
fprintf('Payload: %d bit\n', numel(payload));
fprintf('H_used : %d x %d\n', size(H_used,1), size(H_used,2));
fprintf('Ky vong output codeword: %d bit\n', N);
fprintf('\nBam Run tren Simulink hoac chay: sim(''%s'')\n', model);
fprintf('Sau khi run, kiem tra: size(codeword)\n');
fprintf('Neu output bi them chieu thoi gian, dung codeword(end,:) hoac codeword(:) tuy SaveFormat.\n');

open_system(model);
