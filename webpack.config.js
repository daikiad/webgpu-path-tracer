const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = (_env, argv) => {
    const isProduction = argv.mode === 'production';

    return {
        mode: argv.mode ?? 'development',
        entry: {
            'main': './src/main.ts'
        },
        devtool: isProduction ? false : 'inline-source-map',

        module: {
            rules: [
                {
                    test: /\.ts$/,
                    use: 'ts-loader',
                    exclude: /src\/tmp/,
                },
                {
                    test: /\.wgsl$/,
                    use: 'raw-loader'
                },
                {
                    test: /\.(obj|mtl|bin|glb|gltf|fbx|usdc|usdz)$/,
                    use: [
                        {
                            loader: 'file-loader',
                            options: {
                                name: '[name].[ext]',
                                outputPath: 'scenes/'
                            }
                        }
                    ]
                }
            ]
        },
        resolve: {
            extensions: [
                '.ts', '.js', '.wgsl', '.obj'
            ]
        },
        output: {
            filename: '[name].js',
            path: path.resolve(__dirname, 'dist'),
            // GitHub Pages はサブパス配信なので相対パスにする
            publicPath: './',
            clean: true,
        },
        plugins: [
            new HtmlWebpackPlugin({
                template: './index.html',
                inject: 'body',
            }),
        ],
        devServer: {
            static: [
                {
                    directory: path.join(__dirname, 'dist')
                }
            ],
            compress: true,
            port: 9000
        }
    };
};
