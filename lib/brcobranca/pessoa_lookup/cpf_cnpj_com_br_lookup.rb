# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Brcobranca
  module PessoaLookup
    # Fonte de dados de referência apoiada na API pública de
    # https://www.cpfcnpj.com.br.
    #
    # A consulta segue o formato:
    #
    #   GET https://api.cpfcnpj.com.br/{token}/{pacote}/{documento}
    #
    # Pacotes utilizados:
    #
    # * 3 - CPF: nome e endereço;
    # * 5 - CNPJ: razão social e endereço;
    # * 6 - CNPJ: superset do pacote 5 (situação, porte, Simples Nacional).
    #
    # O corpo é um JSON cujo campo +status+ vale 1 em caso de sucesso e 0 em
    # caso de erro. O token é obtido no painel, em API > Tokens.
    #
    # A implementação usa apenas +Net::HTTP+ (biblioteca padrão), com tempo
    # limite configurável e falha fechada: qualquer indisponibilidade levanta
    # uma exceção em vez de devolver dados incompletos.
    class CpfCnpjComBrLookup
      # Host padrão da API.
      HOST_PADRAO = 'api.cpfcnpj.com.br'
      # Tempo limite padrão, em segundos, para abertura e leitura da conexão.
      TIMEOUT_PADRAO = 8

      attr_reader :token, :pacote_cpf, :pacote_cnpj, :host, :timeout

      # @param token [String] token de acesso à API (painel > API > Tokens).
      # @param pacote_cpf [Integer] pacote usado na consulta de CPF (padrão 3).
      # @param pacote_cnpj [Integer] pacote usado na consulta de CNPJ (padrão 5;
      #   use 6 para incluir situação/porte/Simples Nacional).
      # @param host [String] host da API.
      # @param timeout [Integer] tempo limite, em segundos.
      def initialize(token:, pacote_cpf: 3, pacote_cnpj: 5, host: HOST_PADRAO, timeout: TIMEOUT_PADRAO)
        raise ArgumentError, 'token não pode estar em branco' if token.nil? || token.to_s.strip.empty?

        @token = token.to_s
        @pacote_cpf = pacote_cpf
        @pacote_cnpj = pacote_cnpj
        @host = host
        @timeout = timeout
      end

      # Consulta um CPF e devolve o Hash normalizado do sacado.
      #
      # @param cpf [String] CPF com ou sem máscara.
      # @return [Hash]
      def consultar_cpf(cpf)
        corpo = requisitar(pacote_cpf, somente_numeros(cpf))
        pessoa = { documento: somente_numeros(corpo['cpf']), nome: corpo['nome'] }

        normalizar(pessoa.merge(endereco(corpo, corpo['endereco'])))
      end

      # Consulta um CNPJ e devolve o Hash normalizado do sacado.
      #
      # @param cnpj [String] CNPJ com ou sem máscara.
      # @return [Hash]
      def consultar_cnpj(cnpj)
        corpo = requisitar(pacote_cnpj, somente_alfanumericos(cnpj))
        matriz = corpo['matrizEndereco'] || {}
        pessoa = { documento: somente_alfanumericos(corpo['cnpj']), nome: corpo['razao'] }
        logradouro = monta_logradouro(matriz['tipo'], matriz['logradouro'])

        normalizar(pessoa.merge(endereco(matriz, logradouro)))
      end

      private

      def endereco(fonte, logradouro)
        {
          logradouro: logradouro,
          numero: fonte['numero'],
          complemento: fonte['complemento'],
          bairro: fonte['bairro'],
          cep: somente_numeros(fonte['cep']),
          cidade: fonte['cidade'],
          uf: fonte['uf']
        }
      end

      def requisitar(pacote, documento)
        corpo = buscar_json("/#{token}/#{pacote}/#{documento}")

        raise NaoEncontrado, "documento não encontrado: #{documento}" unless corpo['status'].to_i == 1

        corpo
      end

      def buscar_json(caminho)
        resposta = executar(URI::HTTPS.build(host: host, path: caminho))

        raise Indisponivel, "resposta HTTP #{resposta.code}" unless resposta.is_a?(Net::HTTPSuccess)

        JSON.parse(resposta.body)
      rescue Timeout::Error => e
        raise TempoEsgotado, "tempo limite excedido: #{e.message}"
      rescue JSON::ParserError => e
        raise Indisponivel, "resposta ilegível: #{e.message}"
      rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
        raise Indisponivel, "falha de conexão: #{e.message}"
      end

      def executar(uri)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: timeout, read_timeout: timeout) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end
      end

      def normalizar(campos)
        campos.transform_values { |valor| valor.to_s.strip }
      end

      def monta_logradouro(tipo, logradouro)
        tipo = texto(tipo)
        logradouro = texto(logradouro)
        return logradouro if tipo.empty?
        return logradouro if logradouro.downcase.start_with?(tipo.downcase)

        "#{tipo} #{logradouro}".strip
      end

      def texto(valor)
        valor.to_s.strip
      end

      def somente_numeros(valor)
        valor.to_s.gsub(/\D/, '')
      end

      def somente_alfanumericos(valor)
        valor.to_s.gsub(/[^0-9A-Za-z]/, '').upcase
      end
    end
  end
end
